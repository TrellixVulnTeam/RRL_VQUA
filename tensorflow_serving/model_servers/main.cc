/* Copyright 2016 Google Inc. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
==============================================================================*/

// gRPC server implementation of
// tensorflow_serving/apis/prediction_service.proto.
//
// It bring up a standard server to serve a single TensorFlow model using
// command line flags, or multiple models via config file.
//
// ModelServer prioritizes easy invocation over flexibility,
// and thus serves a statically configured set of models. New versions of these
// models will be loaded and managed over time using the
// AvailabilityPreservingPolicy at:
//     tensorflow_serving/core/availability_preserving_policy.h.
// by AspiredVersionsManager at:
//     tensorflow_serving/core/aspired_versions_manager.h
//
// ModelServer has inter-request batching support built-in, by using the
// BatchingSession at:
//     tensorflow_serving/batching/batching_session.h
//
// To serve a single model, run with:
//     $path_to_binary/tensorflow_model_server \
//     --model_base_path=[/tmp/my_model | gs://gcs_address]
// IMPORTANT: Be sure the base path excludes the version directory. For
// example for a model at /tmp/my_model/123, where 123 is the version, the base
// path is /tmp/my_model.
//
// To specify model name (default "default"): --model_name=my_name
// To specify port (default 8500): --port=my_port
// To enable batching (default disabled): --enable_batching
// To override the default batching parameters: --batching_parameters_file

#include <unistd.h>
#include <iostream>
#include <memory>
#include <utility>
#include <vector>
#include <fstream>
#include <thread>

#include "google/protobuf/wrappers.pb.h"
#include "grpc++/security/server_credentials.h"
#include "grpc++/server.h"
#include "grpc++/server_builder.h"
#include "grpc++/server_context.h"
#include "grpc++/support/status.h"
#include "grpc++/support/status_code_enum.h"
#include "grpc/grpc.h"
#include "tensorflow/core/lib/core/status.h"
#include "tensorflow/core/platform/env.h"
#include "tensorflow/core/platform/init_main.h"
#include "tensorflow/core/platform/protobuf.h"
#include "tensorflow/core/platform/types.h"
#include "tensorflow/core/protobuf/config.pb.h"
#include "tensorflow/core/util/command_line_flags.h"
#include "tensorflow_serving/apis/prediction_service.grpc.pb.h"
#include "tensorflow_serving/apis/prediction_service.pb.h"
#include "tensorflow_serving/config/model_server_config.pb.h"
#include "tensorflow_serving/core/availability_preserving_policy.h"
#include "tensorflow_serving/model_servers/model_platform_types.h"
#include "tensorflow_serving/model_servers/platform_config_util.h"
#include "tensorflow_serving/model_servers/server_core.h"
#include "tensorflow_serving/servables/tensorflow/classification_service.h"
#include "tensorflow_serving/servables/tensorflow/get_model_metadata_impl.h"
#include "tensorflow_serving/servables/tensorflow/multi_inference.h"
#include "tensorflow_serving/servables/tensorflow/predict_impl.h"
#include "tensorflow_serving/servables/tensorflow/regression_service.h"
#include "tensorflow_serving/servables/tensorflow/session_bundle_config.pb.h"

namespace grpc
{
class ServerCompletionQueue;
} // namespace grpc
using tensorflow::string;
using tensorflow::Tensor;
using tensorflow::serving::AspiredVersionPolicy;
using tensorflow::serving::AspiredVersionsManager;
using tensorflow::serving::AvailabilityPreservingPolicy;
using tensorflow::serving::BatchingParameters;
using tensorflow::serving::EventBus;
using tensorflow::serving::FileSystemStoragePathSourceConfig;
using tensorflow::serving::GetModelMetadataImpl;
using tensorflow::serving::ModelServerConfig;
using tensorflow::serving::ServableState;
using tensorflow::serving::ServerCore;
using tensorflow::serving::SessionBundleConfig;
using tensorflow::serving::TensorflowClassificationServiceImpl;
using tensorflow::serving::TensorflowPredictor;
using tensorflow::serving::TensorflowRegressionServiceImpl;
using tensorflow::serving::UniquePtrWithDeps;

using grpc::InsecureServerCredentials;
using grpc::Server;
using grpc::ServerBuilder;
using grpc::ServerContext;
using tensorflow::serving::ClassificationRequest;
using tensorflow::serving::ClassificationResponse;
using tensorflow::serving::GetModelMetadataRequest;
using tensorflow::serving::GetModelMetadataResponse;
using tensorflow::serving::MultiInferenceRequest;
using tensorflow::serving::MultiInferenceResponse;
using tensorflow::serving::PredictionService;
using tensorflow::serving::PredictRequest;
using tensorflow::serving::PredictResponse;
using tensorflow::serving::RegressionRequest;
using tensorflow::serving::RegressionResponse;

namespace
{

tensorflow::Status ParseProtoTextFile(const string &file,
                                      google::protobuf::Message *message)
{
    std::unique_ptr<tensorflow::ReadOnlyMemoryRegion> file_data;
    TF_RETURN_IF_ERROR(
        tensorflow::Env::Default()->NewReadOnlyMemoryRegionFromFile(file,
                                                                    &file_data));
    string file_data_str(static_cast<const char *>(file_data->data()),
                         file_data->length());
    if (tensorflow::protobuf::TextFormat::ParseFromString(file_data_str,
                                                          message))
    {
        return tensorflow::Status::OK();
    }
    else
    {
        return tensorflow::errors::InvalidArgument("Invalid protobuf file: '", file,
                                                   "'");
    }
}

tensorflow::Status LoadCustomModelConfig(
    const ::google::protobuf::Any &any,
    EventBus<ServableState> *servable_event_bus,
    UniquePtrWithDeps<AspiredVersionsManager> *manager)
{
    LOG(FATAL) // Crash ok
        << "ModelServer does not yet support custom model config.";
}

ModelServerConfig BuildSingleModelConfig(const string &model_name,
                                         const string &model_base_path)
{
    ModelServerConfig config;
    LOG(INFO) << "Building single TensorFlow model file config: "
              << " model_name: " << model_name
              << " model_base_path: " << model_base_path;
    tensorflow::serving::ModelConfig *single_model =
        config.mutable_model_config_list()->add_config();
    single_model->set_name(model_name);
    single_model->set_base_path(model_base_path);
    single_model->set_model_platform(
        tensorflow::serving::kTensorFlowModelPlatform);
    return config;
}

template <typename ProtoType>
ProtoType ReadProtoFromFile(const string &file)
{
    ProtoType proto;
    TF_CHECK_OK(ParseProtoTextFile(file, &proto));
    return proto;
}

int DeadlineToTimeoutMillis(const gpr_timespec deadline)
{
    return gpr_time_to_millis(
        gpr_time_sub(gpr_convert_clock_type(deadline, GPR_CLOCK_MONOTONIC),
                     gpr_now(GPR_CLOCK_MONOTONIC)));
}

grpc::Status ToGRPCStatus(const tensorflow::Status &status)
{
    const int kErrorMessageLimit = 1024;
    string error_message;
    if (status.error_message().length() > kErrorMessageLimit)
    {
        error_message =
            status.error_message().substr(0, kErrorMessageLimit) + "...TRUNCATED";
    }
    else
    {
        error_message = status.error_message();
    }
    return grpc::Status(static_cast<grpc::StatusCode>(status.code()),
                        error_message);
}

class PredictionServiceImpl final : public PredictionService::Service
{
  public:
    explicit PredictionServiceImpl(std::unique_ptr<ServerCore> core,
                                   bool use_saved_model)
        : core_(std::move(core)),
          predictor_(new TensorflowPredictor(use_saved_model)),
          use_saved_model_(use_saved_model)
    {
        std::fstream myfile("number_of_request.txt", std::ios_base::in);
        myfile >> qy_total_request_count;
        myfile.close();
        myfile.clear();
        myfile.open("interarrival_time_generated.txt", std::ios_base::in);
        double number;
        while(myfile >> number)
            interarrival_time_generated.push_back(number);
        myfile.close();
    }
    int qy_request_count = 0; //if this count
    int qy_income_request_count = 0;
    int qy_total_request_count;
    double total_waiting_time=0;
    std::vector<double>interarrival_time_generated;
    grpc::Status Predict(ServerContext *context, const PredictRequest *request,
                         PredictResponse *response) override
    {
        total_waiting_time=total_waiting_time+interarrival_time_generated[qy_income_request_count];
        std::chrono::duration<double> t_time(total_waiting_time);
        qy_income_request_count++;
        if (qy_income_request_count>=interarrival_time_generated.size())
        {
            qy_income_request_count=qy_income_request_count-interarrival_time_generated.size();
        }
        std::this_thread::sleep_for(t_time);
        tensorflow::RunOptions run_options = tensorflow::RunOptions();
        // By default, this is infinite which is the same default as RunOptions.
        run_options.set_timeout_in_ms(
            DeadlineToTimeoutMillis(context->raw_deadline()));
        //run_options.set_timeout_in_ms(900000999);
        //START
        int64_t start_time = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
        const grpc::Status status = ToGRPCStatus(
            predictor_->Predict(run_options, core_.get(), *request, response));
        int64_t end_time = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
        Tensor::tensor_m.lock();
        std::cout << "main.cc," << (end_time - start_time) << "," << qy_request_count << "," << qy_total_request_count << std::endl;
        Tensor::tensor_m.unlock();

        //END
        if (!status.ok())
        {
            VLOG(1) << "Predict failed: " << status.error_message();
        }
        else
        {
            if (qy_request_count > 0)
            {
                std::ofstream outfile;
                outfile.open("main.txt", std::ios_base::app);
                if (outfile.fail())
                    std::cout << errno;
                std::cout << end_time - start_time << std::endl;
                outfile << end_time - start_time << std::endl;
                outfile.close();
                outfile.open("main_start.txt", std::ios_base::app);
                if (outfile.fail())
                    std::cout << errno;
                outfile << start_time << std::endl;
                outfile.close();
                outfile.open("main_end.txt", std::ios_base::app);
                if (outfile.fail())
                    std::cout << errno;
                outfile << end_time << std::endl;
                outfile.close();
            }

            qy_request_count++;
            if (qy_request_count > qy_total_request_count)
            {
                std::cout<<qy_request_count<<" is larger than "<<qy_total_request_count<<std::endl;
                exit(0);
            }
        }
        return status;
    }

    grpc::Status GetModelMetadata(ServerContext *context,
                                  const GetModelMetadataRequest *request,
                                  GetModelMetadataResponse *response) override
    {
        if (!use_saved_model_)
        {
            return ToGRPCStatus(tensorflow::errors::InvalidArgument(
                "GetModelMetadata API is only available when use_saved_model is "
                "set to true"));
        }
        const grpc::Status status =
            ToGRPCStatus(GetModelMetadataImpl::GetModelMetadata(
                core_.get(), *request, response));
        if (!status.ok())
        {
            VLOG(1) << "GetModelMetadata failed: " << status.error_message();
        }
        return status;
    }

    grpc::Status Classify(ServerContext *context,
                          const ClassificationRequest *request,
                          ClassificationResponse *response) override
    {
        tensorflow::RunOptions run_options = tensorflow::RunOptions();
        // By default, this is infinite which is the same default as RunOptions.
        run_options.set_timeout_in_ms(
            DeadlineToTimeoutMillis(context->raw_deadline()));
        const grpc::Status status =
            ToGRPCStatus(TensorflowClassificationServiceImpl::Classify(
                run_options, core_.get(), *request, response));
        if (!status.ok())
        {
            VLOG(1) << "Classify request failed: " << status.error_message();
        }
        return status;
    }

    grpc::Status Regress(ServerContext *context,
                         const RegressionRequest *request,
                         RegressionResponse *response) override
    {
        tensorflow::RunOptions run_options = tensorflow::RunOptions();
        // By default, this is infinite which is the same default as RunOptions.
        run_options.set_timeout_in_ms(
            DeadlineToTimeoutMillis(context->raw_deadline()));
        const grpc::Status status =
            ToGRPCStatus(TensorflowRegressionServiceImpl::Regress(
                run_options, core_.get(), *request, response));
        if (!status.ok())
        {
            VLOG(1) << "Regress request failed: " << status.error_message();
        }
        return status;
    }

    grpc::Status MultiInference(ServerContext *context,
                                const MultiInferenceRequest *request,
                                MultiInferenceResponse *response) override
    {
        tensorflow::RunOptions run_options = tensorflow::RunOptions();
        // By default, this is infinite which is the same default as RunOptions.
        run_options.set_timeout_in_ms(
            DeadlineToTimeoutMillis(context->raw_deadline()));
        const grpc::Status status = ToGRPCStatus(
            RunMultiInference(run_options, core_.get(), *request, response));
        if (!status.ok())
        {
            VLOG(1) << "MultiInference request failed: " << status.error_message();
        }
        return status;
    }

  private:
    std::unique_ptr<ServerCore> core_;
    std::unique_ptr<TensorflowPredictor> predictor_;
    bool use_saved_model_;
};

void RunServer(int port, std::unique_ptr<ServerCore> core,
               bool use_saved_model)
{
    // "0.0.0.0" is the way to listen on localhost in gRPC.

    const string server_address = "0.0.0.0:" + std::to_string(port);
    PredictionServiceImpl service(std::move(core), use_saved_model);
    ServerBuilder builder;
    std::shared_ptr<grpc::ServerCredentials> creds = InsecureServerCredentials();
    builder.AddListeningPort(server_address, creds);
    builder.RegisterService(&service);
    builder.SetMaxMessageSize(tensorflow::kint32max);
    std::unique_ptr<Server> server(builder.BuildAndStart());
    LOG(INFO) << "Running ModelServer at " << server_address << " ...";
    std::ofstream outfile ("flag_server_initilized");
    outfile << "flag_server_initilized" << std::endl;
    outfile.close();
    server->Wait();
}

// Parses an ascii PlatformConfigMap protobuf from 'file'.
tensorflow::serving::PlatformConfigMap ParsePlatformConfigMap(
    const string &file)
{
    tensorflow::serving::PlatformConfigMap platform_config_map;
    TF_CHECK_OK(ParseProtoTextFile(file, &platform_config_map));
    return platform_config_map;
}

} // namespace

int main(int argc, char **argv)
{
    tensorflow::int32 port = 8500;
    tensorflow::int32 batch_size = 50;
    tensorflow::int32 inter_op = 10;
    tensorflow::int32 intra_op = 10;
    tensorflow::int32 batch_queue = 10;
    tensorflow::int32 batch_timeout = 1000000;
    tensorflow::int32 batch_threads = 1;
    bool enable_batching = false;
    float per_process_gpu_memory_fraction = 0;
    tensorflow::string batching_parameters_file;
    tensorflow::string model_name = "default";
    tensorflow::int32 file_system_poll_wait_seconds = 1;
    tensorflow::string model_base_path;
    const bool use_saved_model = true;
    // Tensorflow session parallelism of zero means that both inter and intra op
    // thread pools will be auto configured.
    tensorflow::int64 tensorflow_session_parallelism = 0;
    string platform_config_file = "";
    string model_config_file;
    std::vector<tensorflow::Flag> flag_list = {
        tensorflow::Flag("port", &port, "port to listen on"),
        tensorflow::Flag("batch_size", &batch_size, "Maximum Batch Size"),
        tensorflow::Flag("inter_op", &inter_op, "inter op"),
        tensorflow::Flag("intra_op", &intra_op, "intra op"),
        tensorflow::Flag("batch_queue", &batch_queue, "Max batch queue length"),
        tensorflow::Flag("batch_timeout", &batch_timeout, "Timeout wait for batching in microseconds"),
        tensorflow::Flag("batch_threads", &batch_threads, "Max number of parallel batches"),
        tensorflow::Flag("enable_batching", &enable_batching, "enable batching"),
        tensorflow::Flag("batching_parameters_file", &batching_parameters_file,
                         "If non-empty, read an ascii BatchingParameters "
                         "protobuf from the supplied file name and use the "
                         "contained values instead of the defaults."),
        tensorflow::Flag("model_config_file", &model_config_file,
                         "If non-empty, read an ascii ModelServerConfig "
                         "protobuf from the supplied file name, and serve the "
                         "models in that file. This config file can be used to "
                         "specify multiple models to serve and other advanced "
                         "parameters including non-default version policy. (If "
                         "used, --model_name, --model_base_path are ignored.)"),
        tensorflow::Flag("model_name", &model_name,
                         "name of model (ignored "
                         "if --model_config_file flag is set"),
        tensorflow::Flag("model_base_path", &model_base_path,
                         "path to export (ignored if --model_config_file flag "
                         "is set, otherwise required)"),
        tensorflow::Flag("file_system_poll_wait_seconds",
                         &file_system_poll_wait_seconds,
                         "interval in seconds between each poll of the file "
                         "system for new model version"),
        tensorflow::Flag("tensorflow_session_parallelism",
                         &tensorflow_session_parallelism,
                         "Number of threads to use for running a "
                         "Tensorflow session. Auto-configured by default."
                         "Note that this option is ignored if "
                         "--platform_config_file is non-empty."),
        tensorflow::Flag("platform_config_file", &platform_config_file,
                         "If non-empty, read an ascii PlatformConfigMap protobuf "
                         "from the supplied file name, and use that platform "
                         "config instead of the Tensorflow platform. (If used, "
                         "--enable_batching is ignored.)"),
        tensorflow::Flag(
            "per_process_gpu_memory_fraction", &per_process_gpu_memory_fraction,
            "Fraction that each process occupies of the GPU memory space "
            "the value is between 0.0 and 1.0 (with 0.0 as the default) "
            "If 1.0, the server will allocate all the memory when the server "
            "starts, If 0.0, Tensorflow will automatically select a value.")};

    string usage = tensorflow::Flags::Usage(argv[0], flag_list);
    const bool parse_result = tensorflow::Flags::Parse(&argc, argv, flag_list);
    if (!parse_result || (model_base_path.empty() && model_config_file.empty()))
    {
        std::cout << usage;
        return -1;
    }
    tensorflow::port::InitMain(argv[0], &argc, &argv);
    if (argc != 1)
    {
        std::cout << "unknown argument: " << argv[1] << "\n"
                  << usage;
    }

    // For ServerCore Options, we leave servable_state_monitor_creator unspecified
    // so the default servable_state_monitor_creator will be used.
    ServerCore::Options options;

    // model server config
    if (model_config_file.empty())
    {
        options.model_server_config =
            BuildSingleModelConfig(model_name, model_base_path);
    }
    else
    {
        options.model_server_config =
            ReadProtoFromFile<ModelServerConfig>(model_config_file);
    }

    if (platform_config_file.empty())
    {
        SessionBundleConfig session_bundle_config;
        // Batching config
        if (enable_batching)
        {
            std::cout << "Batching Enabled" << std::endl;
            BatchingParameters *batching_parameters =
                session_bundle_config.mutable_batching_parameters();
            ////Update
            session_bundle_config.mutable_batching_parameters()
                ->mutable_max_batch_size()
                ->set_value(batch_size);
            session_bundle_config.mutable_batching_parameters()
                ->mutable_num_batch_threads()
                ->set_value(batch_threads);
            batch_queue=9999999;
            session_bundle_config.mutable_batching_parameters()
                ->mutable_max_enqueued_batches()
                ->set_value(batch_queue);
            session_bundle_config.mutable_batching_parameters()
                ->mutable_batch_timeout_micros()
                ->set_value(batch_timeout);
            //batching_parameters->pad_variable_length_inputs()=true;
            ///
            if (batching_parameters_file.empty())
            {
                batching_parameters->mutable_thread_pool_name()->set_value(
                    "model_server_batch_threads");
            }
            else
            {
                *batching_parameters =
                    ReadProtoFromFile<BatchingParameters>(batching_parameters_file);
            }
        }
        else if (!batching_parameters_file.empty())
        {
            LOG(FATAL) // Crash ok
                << "You supplied --batching_parameters_file without "
                   "--enable_batching";
        }

        //session_bundle_config.mutable_session_config()
        //  ->mutable_gpu_options()
        //->set_per_process_gpu_memory_fraction(per_process_gpu_memory_fraction);
        session_bundle_config.mutable_session_config()
            ->set_intra_op_parallelism_threads(intra_op);
        session_bundle_config.mutable_session_config()
            ->set_inter_op_parallelism_threads(inter_op);

        options.platform_config_map = CreateTensorFlowPlatformConfigMap(
            session_bundle_config, use_saved_model);
    }
    else
    {
        options.platform_config_map = ParsePlatformConfigMap(platform_config_file);
    }

    options.custom_model_config_loader = &LoadCustomModelConfig;

    options.aspired_version_policy =
        std::unique_ptr<AspiredVersionPolicy>(new AvailabilityPreservingPolicy);
    options.file_system_poll_wait_seconds = file_system_poll_wait_seconds;

    std::unique_ptr<ServerCore> core;
    TF_CHECK_OK(ServerCore::Create(std::move(options), &core));
    RunServer(port, std::move(core), use_saved_model);

    return 0;
}
