set -x
# The commands in this file map to steps in this notebook: <TODO>
# The sample scoring file available in the same folder as the above notebook

# script inputs
registry_name="azureml"
subscription_id="<SUBSCRIPTION_ID>"
resource_group_name="<RESOURCE_GROUP>"
workspace_name="<WORKSPACE_NAME>"

# This is the model from system registry that needs to be deployed
model_name="OpenAI-CLIP-Image-Text-Embeddings-vit-base-patch32"
model_label="latest"

version=$(date +%s)
endpoint_name="clip-embeddings-$version"

# Todo: fetch deployment_sku from the min_inference_sku tag of the model
deployment_sku="Standard_DS3_v2"

# Prepare data for deployment
data_path="./data_online"
python ./prepare_data.py --data_path $data_path --mode "online"
# sample_request_data
image_request_data="$data_path/fridgeObjects/image_request_data.json"
text_request_data="$data_path/fridgeObjects/text_request_data.json"
image_text_request_data="$data_path/fridgeObjects/image_text_request_data.json"
# 1. Setup pre-requisites
if [ "$subscription_id" = "<SUBSCRIPTION_ID>" ] || \
   ["$resource_group_name" = "<RESOURCE_GROUP>" ] || \
   [ "$workspace_name" = "<WORKSPACE_NAME>" ]; then 
    echo "Please update the script with the subscription_id, resource_group_name and workspace_name"
    exit 1
fi

az account set -s $subscription_id
workspace_info="--resource-group $resource_group_name --workspace-name $workspace_name"

# 2. Check if the model exists in the registry
# Need to confirm model show command works for registries outside the tenant (aka system registry)
if ! az ml model show --name $model_name --label $model_label --registry-name $registry_name 
then
    echo "Model $model_name:$model_label does not exist in registry $registry_name"
    exit 1
fi

# Get the latest model version
model_version=$(az ml model show --name $model_name --label $model_label --registry-name $registry_name --query version --output tsv)

# 3. Deploy the model to an endpoint
# Create online endpoint 
az ml online-endpoint create --name $endpoint_name $workspace_info  || {
    echo "endpoint create failed"; exit 1;
}

# Deploy model from registry to endpoint in workspace
az ml online-deployment create --file deploy-online.yaml $workspace_info --set \
  endpoint_name=$endpoint_name model=azureml://registries/$registry_name/models/$model_name/versions/$model_version \
  instance_type=$deployment_sku || {
    echo "deployment create failed"; exit 1;
}

# get deployment name and set all traffic to the new deployment
yaml_file="deploy-online.yaml"
get_yaml_value() {
    grep "$1:" "$yaml_file" | awk '{print $2}' | sed 's/[",]//g'
}
deployment_name=$(get_yaml_value "name")

az ml online-endpoint update $workspace_info --name=$endpoint_name --traffic="$deployment_name=100" || {
    echo "Failed to set all traffic to the new deployment"
    exit 1
}

# 4.1 Try a sample scoring request for image embeddings

# Check if scoring data file exists
if [ -f $image_request_data ]; then
    echo "Invoking endpoint $endpoint_name with $image_request_data\n\n"
else
    echo "Scoring file $image_request_data does not exist"
    exit 1
fi

az ml online-endpoint invoke --name $endpoint_name --request-file $image_request_data $workspace_info || {
    echo "endpoint invoke failed"; exit 1;
}
# 4.2 Try a sample scoring request for text embeddings

# Check if scoring data file exists
if [ -f $text_request_data ]; then
    echo "Invoking endpoint $endpoint_name with $text_request_data\n\n"
else
    echo "Scoring file $text_request_data does not exist"
    exit 1
fi

az ml online-endpoint invoke --name $endpoint_name --request-file $text_request_data $workspace_info || {
    echo "endpoint invoke failed"; exit 1;
}
# 4.1 Try a sample scoring request for image and text embeddings

# Check if scoring data file exists
if [ -f $image_text_request_data ]; then
    echo "Invoking endpoint $endpoint_name with $image_text_request_data\n\n"
else
    echo "Scoring file $image_text_request_data does not exist"
    exit 1
fi

az ml online-endpoint invoke --name $endpoint_name --request-file $image_text_request_data $workspace_info || {
    echo "endpoint invoke failed"; exit 1;
}

# 6. Delete the endpoint and sample_request_data.json
az ml online-endpoint delete --name $endpoint_name $workspace_info --yes || {
    echo "endpoint delete failed"; exit 1;
}

rm $image_request_data
rm $text_request_data
rm $image_text_request_data
