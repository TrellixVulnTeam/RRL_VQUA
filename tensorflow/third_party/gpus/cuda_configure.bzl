# -*- Python -*-
"""Repository rule for CUDA autoconfiguration.

`cuda_configure` depends on the following environment variables:

  * `TF_NEED_CUDA`: Whether to enable building with CUDA.
  * `GCC_HOST_COMPILER_PATH`: The GCC host compiler path
  * `TF_CUDA_CLANG`: Whether to use clang as a cuda compiler.
  * `CLANG_CUDA_COMPILER_PATH`: The clang compiler path that will be used for
    both host and device code compilation if TF_CUDA_CLANG is 1.
  * `CUDA_TOOLKIT_PATH`: The path to the CUDA toolkit. Default is
    `/usr/local/cuda`.
  * `TF_CUDA_VERSION`: The version of the CUDA toolkit. If this is blank, then
    use the system default.
  * `TF_CUDNN_VERSION`: The version of the cuDNN library.
  * `CUDNN_INSTALL_PATH`: The path to the cuDNN library. Default is
    `/usr/local/cuda`.
  * `TF_CUDA_COMPUTE_CAPABILITIES`: The CUDA compute capabilities. Default is
    `3.5,5.2`.
"""

_GCC_HOST_COMPILER_PATH = "GCC_HOST_COMPILER_PATH"
_CLANG_CUDA_COMPILER_PATH = "CLANG_CUDA_COMPILER_PATH"
_CUDA_TOOLKIT_PATH = "CUDA_TOOLKIT_PATH"
_TF_CUDA_VERSION = "TF_CUDA_VERSION"
_TF_CUDNN_VERSION = "TF_CUDNN_VERSION"
_CUDNN_INSTALL_PATH = "CUDNN_INSTALL_PATH"
_TF_CUDA_COMPUTE_CAPABILITIES = "TF_CUDA_COMPUTE_CAPABILITIES"
_TF_CUDA_CONFIG_REPO = "TF_CUDA_CONFIG_REPO"

_DEFAULT_CUDA_VERSION = ""
_DEFAULT_CUDNN_VERSION = ""
_DEFAULT_CUDA_TOOLKIT_PATH = "/usr/local/cuda"
_DEFAULT_CUDNN_INSTALL_PATH = "/usr/local/cuda"
_DEFAULT_CUDA_COMPUTE_CAPABILITIES = ["3.5", "5.2"]


# TODO(dzc): Once these functions have been factored out of Bazel's
# cc_configure.bzl, load them from @bazel_tools instead.
# BEGIN cc_configure common functions.
def find_cc(repository_ctx):
  """Find the C++ compiler."""
  # On Windows, we use Bazel's MSVC CROSSTOOL for GPU build
  # Return a dummy value for GCC detection here to avoid error
  if _is_windows(repository_ctx):
    return "/use/--config=win-cuda --cpu=x64_windows_msvc/instead"

  if _use_cuda_clang(repository_ctx):
    target_cc_name = "clang"
    cc_path_envvar = _CLANG_CUDA_COMPILER_PATH
  else:
    target_cc_name = "gcc-5"
    cc_path_envvar = _GCC_HOST_COMPILER_PATH
  cc_name = target_cc_name

  if cc_path_envvar in repository_ctx.os.environ:
    cc_name_from_env = repository_ctx.os.environ[cc_path_envvar].strip()
    if cc_name_from_env:
      cc_name = cc_name_from_env
  if cc_name.startswith("/"):
    # Absolute path, maybe we should make this supported by our which function.
    return cc_name
  cc = repository_ctx.which(cc_name)
  if cc == None:
    fail(("Cannot find {}, either correct your path or set the {}" +
          " environment variable").format(target_cc_name, cc_path_envvar))
  return cc


_INC_DIR_MARKER_BEGIN = "#include <...>"


# OSX add " (framework directory)" at the end of line, strip it.
_OSX_FRAMEWORK_SUFFIX = " (framework directory)"
_OSX_FRAMEWORK_SUFFIX_LEN =  len(_OSX_FRAMEWORK_SUFFIX)
def _cxx_inc_convert(path):
  """Convert path returned by cc -E xc++ in a complete path."""
  path = path.strip()
  if path.endswith(_OSX_FRAMEWORK_SUFFIX):
    path = path[:-_OSX_FRAMEWORK_SUFFIX_LEN].strip()
  return path

def _get_cxx_inc_directories_impl(repository_ctx, cc, lang_is_cpp):
  """Compute the list of default C or C++ include directories."""
  if lang_is_cpp:
    lang = "c++"
  else:
    lang = "c"
  # TODO: We pass -no-canonical-prefixes here to match the compiler flags,
  #       but in cuda_clang CROSSTOOL file that is a `feature` and we should
  #       handle the case when it's disabled and no flag is passed
  result = repository_ctx.execute([cc, "-no-canonical-prefixes",
                                   "-E", "-x" + lang, "-", "-v"])
  index1 = result.stderr.find(_INC_DIR_MARKER_BEGIN)
  if index1 == -1:
    return []
  index1 = result.stderr.find("\n", index1)
  if index1 == -1:
    return []
  index2 = result.stderr.rfind("\n ")
  if index2 == -1 or index2 < index1:
    return []
  index2 = result.stderr.find("\n", index2 + 1)
  if index2 == -1:
    inc_dirs = result.stderr[index1 + 1:]
  else:
    inc_dirs = result.stderr[index1 + 1:index2].strip()

  return [str(repository_ctx.path(_cxx_inc_convert(p)))
          for p in inc_dirs.split("\n")]

def get_cxx_inc_directories(repository_ctx, cc):
  """Compute the list of default C and C++ include directories."""
  # For some reason `clang -xc` sometimes returns include paths that are
  # different from the ones from `clang -xc++`. (Symlink and a dir)
  # So we run the compiler with both `-xc` and `-xc++` and merge resulting lists
  includes_cpp = _get_cxx_inc_directories_impl(repository_ctx, cc, True)
  includes_c = _get_cxx_inc_directories_impl(repository_ctx, cc, False)

  includes_cpp_set = depset(includes_cpp)
  return includes_cpp + [inc for inc in includes_c
                         if inc not in includes_cpp_set]


def auto_configure_fail(msg):
  """Output failure message when cuda configuration fails."""
  red = "\033[0;31m"
  no_color = "\033[0m"
  fail("\n%sCuda Configuration Error:%s %s\n" % (red, no_color, msg))
# END cc_configure common functions (see TODO above).


def _host_compiler_includes(repository_ctx, cc):
  """Generates the cxx_builtin_include_directory entries for gcc inc dirs.

  Args:
    repository_ctx: The repository context.
    cc: The path to the gcc host compiler.

  Returns:
    A string containing the cxx_builtin_include_directory for each of the gcc
    host compiler include directories, which can be added to the CROSSTOOL
    file.
  """
  inc_dirs = get_cxx_inc_directories(repository_ctx, cc)
  inc_entries = []
  for inc_dir in inc_dirs:
    inc_entries.append("  cxx_builtin_include_directory: \"%s\"" % inc_dir)
  return "\n".join(inc_entries)

def _cuda_include_path(repository_ctx, cuda_config):
  """Generates the cxx_builtin_include_directory entries for cuda inc dirs.

  Args:
    repository_ctx: The repository context.
    cc: The path to the gcc host compiler.

  Returns:
    A string containing the cxx_builtin_include_directory for each of the gcc
    host compiler include directories, which can be added to the CROSSTOOL
    file.
  """
  nvcc_path = repository_ctx.path("%s/bin/nvcc%s" %
                                  (cuda_config.cuda_toolkit_path,
                                   ".exe" if cuda_config.cpu_value == "Windows" else ""))
  result = repository_ctx.execute([nvcc_path, '-v',
                                  '/dev/null', '-o', '/dev/null'])
  target_dir = ""
  for one_line in result.stderr.splitlines():
    if one_line.startswith('#$ _TARGET_DIR_='):
      target_dir = (cuda_config.cuda_toolkit_path + '/' +
                    one_line.replace('#$ _TARGET_DIR_=', '') + "/include")
  inc_entries = []
  if target_dir != "":
    inc_entries.append("  cxx_builtin_include_directory: \"%s\"" % target_dir)
  default_include = cuda_config.cuda_toolkit_path + '/include'
  inc_entries.append("  cxx_builtin_include_directory: \"%s\"" %
                     default_include)
  return "\n".join(inc_entries)


def _enable_cuda(repository_ctx):
  if "TF_NEED_CUDA" in repository_ctx.os.environ:
    enable_cuda = repository_ctx.os.environ["TF_NEED_CUDA"].strip()
    return enable_cuda == "1"
  return False


def _cuda_toolkit_path(repository_ctx):
  """Finds the cuda toolkit directory.

  Args:
    repository_ctx: The repository context.

  Returns:
    A speculative real path of the cuda toolkit install directory.
  """
  cuda_toolkit_path = _DEFAULT_CUDA_TOOLKIT_PATH
  if _CUDA_TOOLKIT_PATH in repository_ctx.os.environ:
    cuda_toolkit_path = repository_ctx.os.environ[_CUDA_TOOLKIT_PATH].strip()
  if not repository_ctx.path(cuda_toolkit_path).exists:
    auto_configure_fail("Cannot find cuda toolkit path.")
  return str(repository_ctx.path(cuda_toolkit_path).realpath)


def _cudnn_install_basedir(repository_ctx):
  """Finds the cudnn install directory."""
  cudnn_install_path = _DEFAULT_CUDNN_INSTALL_PATH
  if _CUDNN_INSTALL_PATH in repository_ctx.os.environ:
    cudnn_install_path = repository_ctx.os.environ[_CUDNN_INSTALL_PATH].strip()
  if not repository_ctx.path(cudnn_install_path).exists:
    auto_configure_fail("Cannot find cudnn install path.")
  return cudnn_install_path


def _matches_version(environ_version, detected_version):
  """Checks whether the user-specified version matches the detected version.

  This function performs a weak matching so that if the user specifies only the
  major or major and minor versions, the versions are still considered matching
  if the version parts match. To illustrate:

      environ_version  detected_version  result
      -----------------------------------------
      5.1.3            5.1.3             True
      5.1              5.1.3             True
      5                5.1               True
      5.1.3            5.1               False
      5.2.3            5.1.3             False

  Args:
    environ_version: The version specified by the user via environment
      variables.
    detected_version: The version autodetected from the CUDA installation on
      the system.

  Returns: True if user-specified version matches detected version and False
    otherwise.
  """
  environ_version_parts = environ_version.split(".")
  detected_version_parts = detected_version.split(".")
  if len(detected_version_parts) < len(environ_version_parts):
    return False
  for i, part in enumerate(detected_version_parts):
    if i >= len(environ_version_parts):
      break
    if part != environ_version_parts[i]:
      return False
  return True


_NVCC_VERSION_PREFIX = "Cuda compilation tools, release "


def _cuda_version(repository_ctx, cuda_toolkit_path, cpu_value):
  """Detects the version of CUDA installed on the system.

  Args:
    repository_ctx: The repository context.
    cuda_toolkit_path: The CUDA install directory.

  Returns:
    String containing the version of CUDA.
  """
  # Run nvcc --version and find the line containing the CUDA version.
  nvcc_path = repository_ctx.path("%s/bin/nvcc%s" %
                                  (cuda_toolkit_path,
                                   ".exe" if cpu_value == "Windows" else ""))
  if not nvcc_path.exists:
    auto_configure_fail("Cannot find nvcc at %s" % str(nvcc_path))
  result = repository_ctx.execute([str(nvcc_path), '--version'])
  if result.stderr:
    auto_configure_fail("Error running nvcc --version: %s" % result.stderr)
  lines = result.stdout.splitlines()
  version_line = lines[len(lines) - 1]
  if version_line.find(_NVCC_VERSION_PREFIX) == -1:
    auto_configure_fail(
        "Could not parse CUDA version from nvcc --version. Got: %s" %
        result.stdout)

  # Parse the CUDA version from the line containing the CUDA version.
  prefix_removed = version_line.replace(_NVCC_VERSION_PREFIX, '')
  parts = prefix_removed.split(",")
  if len(parts) != 2 or len(parts[0]) < 2:
    auto_configure_fail(
        "Could not parse CUDA version from nvcc --version. Got: %s" %
        result.stdout)
  full_version = parts[1].strip()
  if full_version.startswith('V'):
    full_version = full_version[1:]

  # Check whether TF_CUDA_VERSION was set by the user and fail if it does not
  # match the detected version.
  environ_version = ""
  if _TF_CUDA_VERSION in repository_ctx.os.environ:
    environ_version = repository_ctx.os.environ[_TF_CUDA_VERSION].strip()
  if environ_version and not _matches_version(environ_version, full_version):
    auto_configure_fail(
        ("CUDA version detected from nvcc (%s) does not match " +
         "TF_CUDA_VERSION (%s)") % (full_version, environ_version))

  # We only use the version consisting of the major and minor version numbers.
  version_parts = full_version.split('.')
  if len(version_parts) < 2:
    auto_configure_fail("CUDA version detected from nvcc (%s) is incomplete.")
  if cpu_value == "Windows":
    version = "64_%s%s" % (version_parts[0], version_parts[1])
  else:
    version = "%s.%s" % (version_parts[0], version_parts[1])
  return version


_DEFINE_CUDNN_MAJOR = "#define CUDNN_MAJOR"
_DEFINE_CUDNN_MINOR = "#define CUDNN_MINOR"
_DEFINE_CUDNN_PATCHLEVEL = "#define CUDNN_PATCHLEVEL"


def _find_cuda_define(repository_ctx, cudnn_header_dir, define):
  """Returns the value of a #define in cudnn.h

  Greps through cudnn.h and returns the value of the specified #define. If the
  #define is not found, then raise an error.

  Args:
    repository_ctx: The repository context.
    cudnn_header_dir: The directory containing the cuDNN header.
    define: The #define to search for.

  Returns:
    The value of the #define found in cudnn.h.
  """
  # Confirm location of cudnn.h and grep for the line defining CUDNN_MAJOR.
  cudnn_h_path = repository_ctx.path("%s/cudnn.h" % cudnn_header_dir)
  if not cudnn_h_path.exists:
    auto_configure_fail("Cannot find cudnn.h at %s" % str(cudnn_h_path))
  result = repository_ctx.execute(["grep", "--color=never", "-E", define, str(cudnn_h_path)])
  if result.stderr:
    auto_configure_fail("Error reading %s: %s" %
                        (result.stderr, str(cudnn_h_path)))

  # Parse the cuDNN major version from the line defining CUDNN_MAJOR
  lines = result.stdout.splitlines()
  if len(lines) == 0 or lines[0].find(define) == -1:
    auto_configure_fail("Cannot find line containing '%s' in %s" %
                        (define, str(cudnn_h_path)))
  return lines[0].replace(define, "").strip()


def _cudnn_version(repository_ctx, cudnn_install_basedir, cpu_value):
  """Detects the version of cuDNN installed on the system.

  Args:
    repository_ctx: The repository context.
    cpu_value: The name of the host operating system.
    cudnn_install_basedir: The cuDNN install directory.

  Returns:
    A string containing the version of cuDNN.
  """
  cudnn_header_dir = _find_cudnn_header_dir(repository_ctx,
                                            cudnn_install_basedir)
  major_version = _find_cuda_define(repository_ctx, cudnn_header_dir,
                                    _DEFINE_CUDNN_MAJOR)
  minor_version = _find_cuda_define(repository_ctx, cudnn_header_dir,
                                    _DEFINE_CUDNN_MINOR)
  patch_version = _find_cuda_define(repository_ctx, cudnn_header_dir,
                                    _DEFINE_CUDNN_PATCHLEVEL)
  full_version = "%s.%s.%s" % (major_version, minor_version, patch_version)

  # Check whether TF_CUDNN_VERSION was set by the user and fail if it does not
  # match the detected version.
  environ_version = ""
  if _TF_CUDNN_VERSION in repository_ctx.os.environ:
    environ_version = repository_ctx.os.environ[_TF_CUDNN_VERSION].strip()
  if environ_version and not _matches_version(environ_version, full_version):
    cudnn_h_path = repository_ctx.path("%s/include/cudnn.h" %
                                       cudnn_install_basedir)
    auto_configure_fail(
        ("cuDNN version detected from %s (%s) does not match " +
        "TF_CUDNN_VERSION (%s)") %
        (str(cudnn_h_path), full_version, environ_version))

  # We only use the major version since we use the libcudnn libraries that are
  # only versioned with the major version (e.g. libcudnn.so.5).
  version = major_version
  if cpu_value == "Windows":
    version = "64_" + version
  return version


def _compute_capabilities(repository_ctx):
  """Returns a list of strings representing cuda compute capabilities."""
  if _TF_CUDA_COMPUTE_CAPABILITIES not in repository_ctx.os.environ:
    return _DEFAULT_CUDA_COMPUTE_CAPABILITIES
  capabilities_str = repository_ctx.os.environ[_TF_CUDA_COMPUTE_CAPABILITIES]
  capabilities = capabilities_str.split(",")
  for capability in capabilities:
    # Workaround for Skylark's lack of support for regex. This check should
    # be equivalent to checking:
    #     if re.match("[0-9]+.[0-9]+", capability) == None:
    parts = capability.split(".")
    if len(parts) != 2 or not parts[0].isdigit() or not parts[1].isdigit():
      auto_configure_fail("Invalid compute capability: %s" % capability)
  return capabilities


def _cpu_value(repository_ctx):
  """Returns the name of the host operating system.

  Args:
    repository_ctx: The repository context.

  Returns:
    A string containing the name of the host operating system.
  """
  os_name = repository_ctx.os.name.lower()
  if os_name.startswith("mac os"):
    return "Darwin"
  if os_name.find("windows") != -1:
    return "Windows"
  result = repository_ctx.execute(["uname", "-s"])
  return result.stdout.strip()


def _is_windows(repository_ctx):
  """Returns true if the host operating system is windows."""
  return _cpu_value(repository_ctx) == "Windows"

def _lib_name(lib, cpu_value, version="", static=False):
  """Constructs the platform-specific name of a library.

  Args:
    lib: The name of the library, such as "cudart"
    cpu_value: The name of the host operating system.
    version: The version of the library.
    static: True the library is static or False if it is a shared object.

  Returns:
    The platform-specific name of the library.
  """
  if cpu_value in ("Linux", "FreeBSD"):
    if static:
      return "lib%s.a" % lib
    else:
      if version:
        version = ".%s" % version
      return "lib%s.so%s" % (lib, version)
  elif cpu_value == "Windows":
    return "%s.lib" % lib
  elif cpu_value == "Darwin":
    if static:
      return "lib%s.a" % lib
    else:
      if version:
        version = ".%s" % version
    return "lib%s%s.dylib" % (lib, version)
  else:
    auto_configure_fail("Invalid cpu_value: %s" % cpu_value)


def _find_cuda_lib(lib, repository_ctx, cpu_value, basedir, version="",
                   static=False):
  """Finds the given CUDA or cuDNN library on the system.

  Args:
    lib: The name of the library, such as "cudart"
    repository_ctx: The repository context.
    cpu_value: The name of the host operating system.
    basedir: The install directory of CUDA or cuDNN.
    version: The version of the library.
    static: True if static library, False if shared object.

  Returns:
    Returns a struct with the following fields:
      file_name: The basename of the library found on the system.
      path: The full path to the library.
  """
  file_name = _lib_name(lib, cpu_value, version, static)
  if cpu_value == "Linux":
    path = repository_ctx.path("%s/lib64/%s" % (basedir, file_name))
    if path.exists:
      return struct(file_name=file_name, path=str(path.realpath))
    path = repository_ctx.path("%s/lib64/stubs/%s" % (basedir, file_name))
    if path.exists:
      return struct(file_name=file_name, path=str(path.realpath))
    path = repository_ctx.path(
        "%s/lib/x86_64-linux-gnu/%s" % (basedir, file_name))
    if path.exists:
      return struct(file_name=file_name, path=str(path.realpath))

  elif cpu_value == "Windows":
    path = repository_ctx.path("%s/lib/x64/%s" % (basedir, file_name))
    if path.exists:
      return struct(file_name=file_name, path=str(path.realpath))

  path = repository_ctx.path("%s/lib/%s" % (basedir, file_name))
  if path.exists:
    return struct(file_name=file_name, path=str(path.realpath))
  path = repository_ctx.path("%s/%s" % (basedir, file_name))
  if path.exists:
    return struct(file_name=file_name, path=str(path.realpath))

  auto_configure_fail("Cannot find cuda library %s" % file_name)


def _find_cupti_lib(repository_ctx, cuda_config):
  """Finds the cupti library on the system.

  On most systems, the cupti library is not installed in the same directory as
  the other CUDA libraries but rather in a special extras/CUPTI directory.

  Args:
    repository_ctx: The repository context.
    cuda_config: The cuda configuration as returned by _get_cuda_config.

  Returns:
    Returns a struct with the following fields:
      file_name: The basename of the library found on the system.
      path: The full path to the library.
  """
  file_name = _lib_name("cupti", cuda_config.cpu_value,
                        cuda_config.cuda_version)
  if cuda_config.cpu_value == "Linux":
    path = repository_ctx.path(
        "%s/extras/CUPTI/lib64/%s" % (cuda_config.cuda_toolkit_path, file_name))
    if path.exists:
      return struct(file_name=file_name, path=str(path.realpath))

    path = repository_ctx.path(
        "%s/lib/x86_64-linux-gnu/%s" % (cuda_config.cuda_toolkit_path,
                                        file_name))
    if path.exists:
      return struct(file_name=file_name, path=str(path.realpath))

  elif cuda_config.cpu_value == "Windows":
    path = repository_ctx.path(
        "%s/extras/CUPTI/libx64/%s" %
        (cuda_config.cuda_toolkit_path, file_name))
    if path.exists:
      return struct(file_name=file_name, path=str(path.realpath))

  path = repository_ctx.path(
      "%s/extras/CUPTI/lib/%s" % (cuda_config.cuda_toolkit_path, file_name))
  if path.exists:
    return struct(file_name=file_name, path=str(path.realpath))

  path = repository_ctx.path(
      "%s/lib/%s" % (cuda_config.cuda_toolkit_path, file_name))
  if path.exists:
    return struct(file_name=file_name, path=str(path.realpath))

  auto_configure_fail("Cannot find cupti library %s" % file_name)

def _find_libs(repository_ctx, cuda_config):
  """Returns the CUDA and cuDNN libraries on the system.

  Args:
    repository_ctx: The repository context.
    cuda_config: The CUDA config as returned by _get_cuda_config

  Returns:
    Map of library names to structs of filename and path as returned by
    _find_cuda_lib and _find_cupti_lib.
  """
  cudnn_version = cuda_config.cudnn_version
  cudnn_ext = ".%s" % cudnn_version if cudnn_version else ""
  cpu_value = cuda_config.cpu_value
  return {
      "cuda": _find_cuda_lib("cuda", repository_ctx, cpu_value, cuda_config.cuda_toolkit_path),
      "cudart": _find_cuda_lib(
          "cudart", repository_ctx, cpu_value, cuda_config.cuda_toolkit_path,
          cuda_config.cuda_version),
      "cudart_static": _find_cuda_lib(
          "cudart_static", repository_ctx, cpu_value,
          cuda_config.cuda_toolkit_path, cuda_config.cuda_version, static=True),
      "cublas": _find_cuda_lib(
          "cublas", repository_ctx, cpu_value, cuda_config.cuda_toolkit_path,
          cuda_config.cuda_version),
      "cusolver": _find_cuda_lib(
          "cusolver", repository_ctx, cpu_value, cuda_config.cuda_toolkit_path,
          cuda_config.cuda_version),
      "curand": _find_cuda_lib(
          "curand", repository_ctx, cpu_value, cuda_config.cuda_toolkit_path,
          cuda_config.cuda_version),
      "cufft": _find_cuda_lib(
          "cufft", repository_ctx, cpu_value, cuda_config.cuda_toolkit_path,
          cuda_config.cuda_version),
      "cudnn": _find_cuda_lib(
          "cudnn", repository_ctx, cpu_value, cuda_config.cudnn_install_basedir,
          cuda_config.cudnn_version),
      "cupti": _find_cupti_lib(repository_ctx, cuda_config),
  }


def _find_cudnn_header_dir(repository_ctx, cudnn_install_basedir):
  """Returns the path to the directory containing cudnn.h

  Args:
    repository_ctx: The repository context.
    cudnn_install_basedir: The cudnn install directory as returned by
      _cudnn_install_basedir.

  Returns:
    The path of the directory containing the cudnn header.
  """
  if repository_ctx.path(cudnn_install_basedir + "/cudnn.h").exists:
    return cudnn_install_basedir
  if repository_ctx.path(cudnn_install_basedir + "/include/cudnn.h").exists:
    return cudnn_install_basedir + "/include"
  if repository_ctx.path("/usr/include/cudnn.h").exists:
    return "/usr/include"
  auto_configure_fail("Cannot find cudnn.h under %s" % cudnn_install_basedir)


def _find_cudnn_lib_path(repository_ctx, cudnn_install_basedir, symlink_files):
  """Returns the path to the directory containing libcudnn

  Args:
    repository_ctx: The repository context.
    cudnn_install_basedir: The cudnn install dir as returned by
      _cudnn_install_basedir.
    symlink_files: The symlink files as returned by _cuda_symlink_files.

  Returns:
    The path of the directory containing the cudnn libraries.
  """
  lib_dir = cudnn_install_basedir + "/" + symlink_files.cuda_dnn_lib
  if repository_ctx.path(lib_dir).exists:
    return lib_dir
  alt_lib_dir = cudnn_install_basedir + "/" + symlink_files.cuda_dnn_lib_alt
  if repository_ctx.path(alt_lib_dir).exists:
    return alt_lib_dir

  auto_configure_fail("Cannot find %s or %s under %s" %
       (symlink_files.cuda_dnn_lib, symlink_files.cuda_dnn_lib_alt,
        cudnn_install_basedir))


def _cudart_static_linkopt(cpu_value):
  """Returns additional platform-specific linkopts for cudart."""
  return "" if cpu_value == "Darwin" else "\"-lrt\","

def _get_cuda_config(repository_ctx):
  """Detects and returns information about the CUDA installation on the system.

  Args:
    repository_ctx: The repository context.

  Returns:
    A struct containing the following fields:
      cuda_toolkit_path: The CUDA toolkit installation directory.
      cudnn_install_basedir: The cuDNN installation directory.
      cuda_version: The version of CUDA on the system.
      cudnn_version: The version of cuDNN on the system.
      compute_capabilities: A list of the system's CUDA compute capabilities.
      cpu_value: The name of the host operating system.
  """
  cpu_value = _cpu_value(repository_ctx)
  cuda_toolkit_path = _cuda_toolkit_path(repository_ctx)
  cuda_version = _cuda_version(repository_ctx, cuda_toolkit_path, cpu_value)
  cudnn_install_basedir = _cudnn_install_basedir(repository_ctx)
  cudnn_version = _cudnn_version(repository_ctx, cudnn_install_basedir, cpu_value)
  return struct(
      cuda_toolkit_path = cuda_toolkit_path,
      cudnn_install_basedir = cudnn_install_basedir,
      cuda_version = cuda_version,
      cudnn_version = cudnn_version,
      compute_capabilities = _compute_capabilities(repository_ctx),
      cpu_value = cpu_value)


def _tpl(repository_ctx, tpl, substitutions={}, out=None):
  if not out:
    out = tpl.replace(":", "/")
  repository_ctx.template(
      out,
      Label("//third_party/gpus/%s.tpl" % tpl),
      substitutions)


def _file(repository_ctx, label):
  repository_ctx.template(
      label.replace(":", "/"),
      Label("//third_party/gpus/%s.tpl" % label),
      {})


_DUMMY_CROSSTOOL_BZL_FILE = """
def error_gpu_disabled():
  fail("ERROR: Building with --config=cuda but TensorFlow is not configured " +
       "to build with GPU support. Please re-run ./configure and enter 'Y' " +
       "at the prompt to build with GPU support.")

  native.genrule(
      name = "error_gen_crosstool",
      outs = ["CROSSTOOL"],
      cmd = "echo 'Should not be run.' && exit 1",
  )

  native.filegroup(
      name = "crosstool",
      srcs = [":CROSSTOOL"],
      output_licenses = ["unencumbered"],
  )
"""


_DUMMY_CROSSTOOL_BUILD_FILE = """
load("//crosstool:error_gpu_disabled.bzl", "error_gpu_disabled")

error_gpu_disabled()
"""


def _create_dummy_repository(repository_ctx):
  cpu_value = _cpu_value(repository_ctx)

  # Set up BUILD file for cuda/.
  _tpl(repository_ctx, "cuda:build_defs.bzl",
       {
           "%{cuda_is_configured}": "False",
           "%{cuda_extra_copts}": "[]"
       })
  _tpl(repository_ctx, "cuda:BUILD",
       {
           "%{cuda_driver_lib}": _lib_name("cuda", cpu_value),
           "%{cudart_static_lib}": _lib_name("cudart_static", cpu_value,
                                             static=True),
           "%{cudart_static_linkopt}": _cudart_static_linkopt(cpu_value),
           "%{cudart_lib}": _lib_name("cudart", cpu_value),
           "%{cublas_lib}": _lib_name("cublas", cpu_value),
           "%{cusolver_lib}": _lib_name("cusolver", cpu_value),
           "%{cudnn_lib}": _lib_name("cudnn", cpu_value),
           "%{cufft_lib}": _lib_name("cufft", cpu_value),
           "%{curand_lib}": _lib_name("curand", cpu_value),
           "%{cupti_lib}": _lib_name("cupti", cpu_value),
           "%{cuda_include_genrules}": '',
           "%{cuda_headers}": '',
       })

  # Create dummy files for the CUDA toolkit since they are still required by
  # tensorflow/core/platform/default/build_config:cuda.
  repository_ctx.file("cuda/cuda/include/cuda.h", "")
  repository_ctx.file("cuda/cuda/include/cublas.h", "")
  repository_ctx.file("cuda/cuda/include/cudnn.h", "")
  repository_ctx.file("cuda/cuda/extras/CUPTI/include/cupti.h", "")
  repository_ctx.file("cuda/cuda/lib/%s" % _lib_name("cuda", cpu_value))
  repository_ctx.file("cuda/cuda/lib/%s" % _lib_name("cudart", cpu_value))
  repository_ctx.file("cuda/cuda/lib/%s" % _lib_name("cudart_static", cpu_value))
  repository_ctx.file("cuda/cuda/lib/%s" % _lib_name("cublas", cpu_value))
  repository_ctx.file("cuda/cuda/lib/%s" % _lib_name("cusolver", cpu_value))
  repository_ctx.file("cuda/cuda/lib/%s" % _lib_name("cudnn", cpu_value))
  repository_ctx.file("cuda/cuda/lib/%s" % _lib_name("curand", cpu_value))
  repository_ctx.file("cuda/cuda/lib/%s" % _lib_name("cufft", cpu_value))
  repository_ctx.file("cuda/cuda/lib/%s" % _lib_name("cupti", cpu_value))

  # Set up cuda_config.h, which is used by
  # tensorflow/stream_executor/dso_loader.cc.
  _tpl(repository_ctx, "cuda:cuda_config.h",
       {
           "%{cuda_version}": _DEFAULT_CUDA_VERSION,
           "%{cudnn_version}": _DEFAULT_CUDNN_VERSION,
           "%{cuda_compute_capabilities}": ",".join([
               "CudaVersion(\"%s\")" % c
               for c in _DEFAULT_CUDA_COMPUTE_CAPABILITIES]),
           "%{cuda_toolkit_path}": _DEFAULT_CUDA_TOOLKIT_PATH,
       }, "cuda/cuda/cuda_config.h")

  # If cuda_configure is not configured to build with GPU support, and the user
  # attempts to build with --config=cuda, add a dummy build rule to intercept
  # this and fail with an actionable error message.
  repository_ctx.file("crosstool/error_gpu_disabled.bzl",
                      _DUMMY_CROSSTOOL_BZL_FILE)
  repository_ctx.file("crosstool/BUILD", _DUMMY_CROSSTOOL_BUILD_FILE)


def _execute(repository_ctx, cmdline, error_msg=None, error_details=None,
             empty_stdout_fine=False):
  """Executes an arbitrary shell command.

  Args:
    repository_ctx: the repository_ctx object
    cmdline: list of strings, the command to execute
    error_msg: string, a summary of the error if the command fails
    error_details: string, details about the error or steps to fix it
    empty_stdout_fine: bool, if True, an empty stdout result is fine, otherwise
      it's an error
  Return:
    the result of repository_ctx.execute(cmdline)
  """
  result = repository_ctx.execute(cmdline)
  if result.stderr or not (empty_stdout_fine or result.stdout):
    auto_configure_fail(
        "\n".join([
            error_msg.strip() if error_msg else "Repository command failed",
            result.stderr.strip(),
            error_details if error_details else ""]))
  return result


def _norm_path(path):
  """Returns a path with '/' and remove the trailing slash."""
  path = path.replace("\\", "/")
  if path[-1] == "/":
    path = path[:-1]
  return path


def _symlink_genrule_for_dir(repository_ctx, src_dir, dest_dir, genrule_name,
    src_files = [], dest_files = []):
  """Returns a genrule to symlink(or copy if on Windows) a set of files.

  If src_dir is passed, files will be read from the given directory; otherwise
  we assume files are in src_files and dest_files
  """
  if src_dir != None:
    src_dir = _norm_path(src_dir)
    dest_dir = _norm_path(dest_dir)
    files = _read_dir(repository_ctx, src_dir)
    # Create a list with the src_dir stripped to use for outputs.
    dest_files = files.replace(src_dir, '').splitlines()
    src_files = files.splitlines()
  command = []
  if not _is_windows(repository_ctx):
    # We clear folders that might have been generated previously to avoid
    # undesired inclusions
    command.append('if [ -d "$(@D)/extras" ]; then rm $(@D)/extras -drf; fi')
    command.append('if [ -d "$(@D)/include" ]; then rm $(@D)/include -drf; fi')
    command.append('if [ -d "$(@D)/lib" ]; then rm $(@D)/lib -drf; fi')
    command.append('if [ -d "$(@D)/nvvm" ]; then rm $(@D)/nvvm -drf; fi')
  outs = []
  for i in range(len(dest_files)):
    if dest_files[i] != "":
      # If we have only one file to link we do not want to use the dest_dir, as
      # $(@D) will include the full path to the file.
      dest = '$(@D)/' + dest_dir + dest_files[i] if len(dest_files) != 1 else '$(@D)/' + dest_files[i]
      # On Windows, symlink is not supported, so we just copy all the files.
      cmd = 'cp -f' if _is_windows(repository_ctx) else 'ln -s'
      command.append(cmd + ' "%s" "%s"' % (src_files[i] , dest))
      outs.append('        "' + dest_dir + dest_files[i] + '",')
  genrule = _genrule(src_dir, genrule_name, " && ".join(command),
                     "\n".join(outs))
  return genrule


def _genrule(src_dir, genrule_name, command, outs):
  """Returns a string with a genrule.

  Genrule executes the given command and produces the given outputs.
  """
  return (
      'genrule(\n' +
      '    name = "' +
      genrule_name + '",\n' +
      '    outs = [\n' +
      outs +
      '\n    ],\n' +
      '    cmd = """\n' +
      command +
      '\n   """,\n' +
      ')\n'
  )


def _read_dir(repository_ctx, src_dir):
  """Returns a string with all files in a directory.

  Finds all files inside a directory, traversing subfolders and following
  symlinks. The returned string contains the full path of all files
  separated by line breaks.
  """
  if _is_windows(repository_ctx):
    src_dir = src_dir.replace("/", "\\")
    find_result = _execute(
        repository_ctx, ["cmd.exe", "/c", "dir", src_dir, "/b", "/s", "/a-d"],
        empty_stdout_fine=True)
    # src_files will be used in genrule.outs where the paths must
    # use forward slashes.
    result = find_result.stdout.replace("\\", "/")
  else:
    find_result = _execute(
        repository_ctx, ["find", src_dir, "-follow", "-type", "f"],
        empty_stdout_fine=True)
    result = find_result.stdout
  return result


def _use_cuda_clang(repository_ctx):
  if "TF_CUDA_CLANG" in repository_ctx.os.environ:
    enable_cuda = repository_ctx.os.environ["TF_CUDA_CLANG"].strip()
    return enable_cuda == "1"
  return False

def _compute_cuda_extra_copts(repository_ctx, compute_capabilities):
  if _use_cuda_clang(repository_ctx):
    capability_flags = ["--cuda-gpu-arch=sm_" +
        cap.replace(".", "") for cap in compute_capabilities]
  else:
    # Capabilities are handled in the "crosstool_wrapper_driver_is_not_gcc" for nvcc
    capability_flags = []
  return str(capability_flags)

def _create_local_cuda_repository(repository_ctx):
  """Creates the repository containing files set up to build with CUDA."""
  cuda_config = _get_cuda_config(repository_ctx)

  cudnn_header_dir = _find_cudnn_header_dir(repository_ctx,
                                            cuda_config.cudnn_install_basedir)

  # Set up symbolic links for the cuda toolkit by creating genrules to do
  # symlinking. We create one genrule for each directory we want to track under
  # cuda_toolkit_path
  cuda_toolkit_path = cuda_config.cuda_toolkit_path
  cuda_include_path = cuda_toolkit_path + "/include"
  genrules = [_symlink_genrule_for_dir(repository_ctx,
      cuda_include_path, "cuda/include", "cuda-include")]
  genrules.append(_symlink_genrule_for_dir(repository_ctx,
      cuda_toolkit_path + "/nvvm", "cuda/nvvm", "cuda-nvvm"))
  genrules.append(_symlink_genrule_for_dir(repository_ctx,
      cuda_toolkit_path + "/extras/CUPTI/include",
      "cuda/extras/CUPTI/include", "cuda-extras"))

  cuda_libs = _find_libs(repository_ctx, cuda_config)
  cuda_lib_src = []
  cuda_lib_dest = []
  for lib in cuda_libs.values():
    cuda_lib_src.append(lib.path)
    cuda_lib_dest.append("cuda/lib/" + lib.file_name)
  genrules.append(_symlink_genrule_for_dir(repository_ctx, None, "", "cuda-lib",
                                       cuda_lib_src, cuda_lib_dest))

  # Set up the symbolic links for cudnn if cudnn was was not installed to
  # CUDA_TOOLKIT_PATH.
  included_files = _read_dir(repository_ctx, cuda_include_path).replace(
      cuda_include_path, '').splitlines()
  if '/cudnn.h' not in included_files:
    genrules.append(_symlink_genrule_for_dir(repository_ctx, None,
        "cuda/include/", "cudnn-include", [cudnn_header_dir + "/cudnn.h"],
        ["cudnn.h"]))
  else:
    genrules.append(
            'filegroup(\n' +
            '    name = "cudnn-include",\n' +
            '    srcs = [],\n' +
            ')\n'
        )

  # Set up BUILD file for cuda/
  _tpl(repository_ctx, "cuda:build_defs.bzl",
       {
           "%{cuda_is_configured}": "True",
           "%{cuda_extra_copts}": _compute_cuda_extra_copts(
               repository_ctx, cuda_config.compute_capabilities),

       })
  _tpl(repository_ctx, "cuda:BUILD",
       {
           "%{cuda_driver_lib}": cuda_libs["cuda"].file_name,
           "%{cudart_static_lib}": cuda_libs["cudart_static"].file_name,
           "%{cudart_static_linkopt}": _cudart_static_linkopt(
               cuda_config.cpu_value),
           "%{cudart_lib}": cuda_libs["cudart"].file_name,
           "%{cublas_lib}": cuda_libs["cublas"].file_name,
           "%{cusolver_lib}": cuda_libs["cusolver"].file_name,
           "%{cudnn_lib}": cuda_libs["cudnn"].file_name,
           "%{cufft_lib}": cuda_libs["cufft"].file_name,
           "%{curand_lib}": cuda_libs["curand"].file_name,
           "%{cupti_lib}": cuda_libs["cupti"].file_name,
           "%{cuda_include_genrules}": "\n".join(genrules),
           "%{cuda_headers}": ('":cuda-include",\n' +
                               '        ":cudnn-include",')
       })
  # Set up crosstool/
  cc = find_cc(repository_ctx)
  host_compiler_includes = _host_compiler_includes(repository_ctx, cc)
  cuda_defines = {
           "%{cuda_include_path}": _cuda_include_path(repository_ctx,
                                                      cuda_config),
           "%{host_compiler_includes}": host_compiler_includes,
       }
  if _use_cuda_clang(repository_ctx):
    cuda_defines["%{clang_path}"] = cc
    _tpl(repository_ctx, "crosstool:BUILD", {"%{linker_files}": ":empty"})
    _tpl(repository_ctx, "crosstool:CROSSTOOL_clang", cuda_defines, out="crosstool/CROSSTOOL")
    repository_ctx.file("crosstool/clang/bin/crosstool_wrapper_driver_is_not_gcc", "")
  else:
    nvcc_path = str(repository_ctx.path("%s/bin/nvcc%s" %
        (cuda_config.cuda_toolkit_path,
        ".exe" if cuda_config.cpu_value == "Windows" else "")))
    _tpl(repository_ctx, "crosstool:BUILD",
         {"%{linker_files}": ":crosstool_wrapper_driver_is_not_gcc"})
    _tpl(repository_ctx, "crosstool:CROSSTOOL_nvcc", cuda_defines, out="crosstool/CROSSTOOL")
    _tpl(repository_ctx,
         "crosstool:clang/bin/crosstool_wrapper_driver_is_not_gcc",
         {
             "%{cpu_compiler}": str(cc),
             "%{cuda_version}": cuda_config.cuda_version,
             "%{nvcc_path}": nvcc_path,
             "%{gcc_host_compiler_path}": str(cc),
             "%{cuda_compute_capabilities}": ", ".join(
                 ["\"%s\"" % c for c in cuda_config.compute_capabilities]),
         })

  # Set up cuda_config.h, which is used by
  # tensorflow/stream_executor/dso_loader.cc.
  _tpl(repository_ctx, "cuda:cuda_config.h",
       {
           "%{cuda_version}": cuda_config.cuda_version,
           "%{cudnn_version}": cuda_config.cudnn_version,
           "%{cuda_compute_capabilities}": ",".join(
               ["CudaVersion(\"%s\")" % c
                for c in cuda_config.compute_capabilities]),
               "%{cuda_toolkit_path}": cuda_config.cuda_toolkit_path,
       }, "cuda/cuda/cuda_config.h")

def _create_remote_cuda_repository(repository_ctx, remote_config_repo):
  """Creates pointers to a remotely configured repo set up to build with CUDA."""
  _tpl(repository_ctx, "cuda:build_defs.bzl",
       {
           "%{cuda_is_configured}": "True",
           "%{cuda_extra_copts}": _compute_cuda_extra_copts(
               repository_ctx, _compute_capabilities(repository_ctx)),

       })
  _tpl(repository_ctx, "cuda:remote.BUILD",
       {
           "%{remote_cuda_repo}": remote_config_repo,
       }, "cuda/BUILD")
  _tpl(repository_ctx, "crosstool:remote.BUILD", {
           "%{remote_cuda_repo}": remote_config_repo,
       }, "crosstool/BUILD")

def _cuda_autoconf_impl(repository_ctx):
  """Implementation of the cuda_autoconf repository rule."""
  if not _enable_cuda(repository_ctx):
    _create_dummy_repository(repository_ctx)
  else:
    if _TF_CUDA_CONFIG_REPO in repository_ctx.os.environ:
      _create_remote_cuda_repository(repository_ctx,
          repository_ctx.os.environ[_TF_CUDA_CONFIG_REPO])
    else:
      _create_local_cuda_repository(repository_ctx)


cuda_configure = repository_rule(
    implementation = _cuda_autoconf_impl,
    environ = [
        _GCC_HOST_COMPILER_PATH,
        "TF_NEED_CUDA",
        _CUDA_TOOLKIT_PATH,
        _CUDNN_INSTALL_PATH,
        _TF_CUDA_VERSION,
        _TF_CUDNN_VERSION,
        _TF_CUDA_COMPUTE_CAPABILITIES,
        _TF_CUDA_CONFIG_REPO,
    ],
)

"""Detects and configures the local CUDA toolchain.

Add the following to your WORKSPACE FILE:

```python
cuda_configure(name = "local_config_cuda")
```

Args:
  name: A unique name for this workspace rule.
"""
