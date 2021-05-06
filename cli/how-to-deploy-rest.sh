#!/bin/bash
set -e

## IMPORTANT: this file and accompanying assets are the source for snippets in https://docs.microsoft.com/azure/machine-learning! 
## Please reach out to the Azure ML docs & samples team before before editing for the first time.

# <create_variables>
SUBSCRIPTION_ID=$(az account show --query id | tr -d '\r"')
LOCATION=$(az group show --query location | tr -d '\r"')
RESOURCE_GROUP=$(az group show --query name | tr -d '\r"')

WORKSPACE=$(az configure -l | jq '.[] | select(.name=="workspace") | .value' | tr -d '"')

API_VERSION="2021-03-01-preview"
COMPUTE_NAME="cpu-cluster"

TOKEN=$(az account get-access-token --query accessToken -o tsv)
#</create_variables>

echo "Using:\nSUBSCRIPTION_ID: $SUBSCRIPTION_ID\nLOCATION: $LOCATION\nRESOURCE_GROUP: $RESOURCE_GROUP\nWORKSPACE: $WORKSPACE"

# define how to wait
wait_for_completion () {
    operation_id=$1
    echo "Using async operation id: $operation_id"
    operation_status="unknown"

    while [[ $operation_status != "Succeeded" && $operation_status != "Failed" ]]
    do
        echo "Getting operation status from: $operation_id"
        operation_result=$(curl --location --request GET $operation_id --header "Authorization: Bearer $TOKEN")
        # TODO error handling here
        operation_status=$(echo $operation_result | jq -r ".status")
        echo "Current operation status: $operation_status"
        sleep 5
    done
}

# Get values for storage account
response=$(curl --location --request GET "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.MachineLearningServices/workspaces/$WORKSPACE/datastores?api-version=$API_VERSION&isDefault=true" \
--header "Authorization: Bearer $TOKEN")

AZURE_STORAGE_ACCOUNT=$(echo $response | jq '.value[0].properties.contents.accountName' | tr -d '\r"')
AZUREML_DEFAULT_DATASTORE=$(echo $response | jq '.value[0].name' | tr -d '\r"')
AZUREML_DEFAULT_CONTAINER=$(echo $response | jq '.value[0].properties.contents.containerName' | tr -d '\r"')
AZURE_STORAGE_KEY=$(az storage account keys list --account-name $AZURE_STORAGE_ACCOUNT | jq '.[0].value')

# delete endpoint
curl --location --request DELETE "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.MachineLearningServices/workspaces/$WORKSPACE/onlineEndpoints/my-endpoint?api-version=$API_VERSION" \
--header "Content-Type: application/json" \
--header "Authorization: Bearer $TOKEN" || true

# TODO: we can get the default container from listing datastores
# TODO using the latter two as env vars shouldn't be necessary
az storage blob upload-batch -d $AZUREML_DEFAULT_CONTAINER/score \
 -s endpoints/online/model-1/onlinescoring --account-name $AZURE_STORAGE_ACCOUNT --account-key $AZURE_STORAGE_KEY

# <create_code>
curl --location --request PUT "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.MachineLearningServices/workspaces/$WORKSPACE/codes/score-sklearn/versions/1?api-version=$API_VERSION" \
--header "Authorization: Bearer $TOKEN" \
--header "Content-Type: application/json" \
--data-raw "{
  \"properties\": {
    \"description\": \"Score code\",
    \"datastoreId\": \"/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.MachineLearningServices/workspaces/$WORKSPACE/datastores/workspaceblobstore\",
    \"path\": \"score\"
  }
}"
# </create_code>

# upload model
az storage blob upload-batch -d $AZUREML_DEFAULT_CONTAINER/model \
 -s endpoints/online/model-1/model --account-name $AZURE_STORAGE_ACCOUNT --account-key $AZURE_STORAGE_KEY

# <create_model>
curl --location --request PUT "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.MachineLearningServices/workspaces/$WORKSPACE/models/sklearn/versions/1?api-version=$API_VERSION" \
--header "Authorization: Bearer $TOKEN" \
--header "Content-Type: application/json" \
--data-raw "{
    \"properties\": {
        \"datastoreId\":\"/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.MachineLearningServices/workspaces/$WORKSPACE/datastores/workspaceblobstore\",
        \"path\": \"model/sklearn_regression_model.pkl\",
    }
}"
# </create_model>

# <create_environment>
curl --location --request PUT "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.MachineLearningServices/workspaces/$WORKSPACE/environments/sklearn-env/versions/1?api-version=$API_VERSION" \
--header "Authorization: Bearer $TOKEN" \
--header "Content-Type: application/json" \
--data-raw "{
    \"properties\":{
        \"condaFile\": \"channels:\n  - conda-forge\ndependencies:\n  - python=3.6.1\n  - numpy\n  - pip\n  - scikit-learn==0.19.1\n  - scipy\n  - pip:\n    - azureml-defaults\n    - inference-schema[numpy-support]\n    - joblib\n    - numpy\n    - scikit-learn==0.19.1\n    - scipy\",
        \"Docker\": {
            \"DockerSpecificationType\": \"Image\",
            \"DockerImageUri\": \"mcr.microsoft.com/azureml/intelmpi2018.3-ubuntu16.04:20210301.v1\"
        }
    }
}"
# </create_environment>

# TODO: had to change syntax to get headers
#<create_endpoint>
headers=$(curl -i -H --location --request PUT "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.MachineLearningServices/workspaces/$WORKSPACE/onlineEndpoints/my-endpoint?api-version=$API_VERSION" \
--header "Content-Type: application/json" \
--header "Authorization: Bearer $TOKEN" \
--data-raw "{
    \"identity\": {
       \"type\": \"systemAssigned\"
    },
    \"properties\": {
        \"authMode\": \"AMLToken\",
        \"traffic\": { \"blue\": 100 }
    },
    \"location\": \"$LOCATION\"
}")
#</create_endpoint>

echo "Endpoint headers: $headers"
operation_id=$(echo $headers | grep -Fi azure-asyncoperation | sed "s/azure-asyncoperation: //" | tr -d '\r\\')
wait_for_completion $operation_id

# <create_deployment>
headers=$(curl -i -H --location --request PUT "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.MachineLearningServices/workspaces/$WORKSPACE/onlineEndpoints/my-endpoint/deployments/blue?api-version=$API_VERSION" \
--header "Content-Type: application/json" \
--header "Authorization: Bearer $TOKEN" \
--data-raw "{
    \"location\": \"$LOCATION\",
    \"properties\": {
        \"endpointComputeType\": \"Managed\",
        \"scaleSettings\": {
            \"scaleType\": \"Manual\",
            \"instanceCount\": 1,
            \"minInstances\": 1,
            \"maxInstances\": 2
        },
        \"model\": {
            \"referenceType\": \"Id\",
            \"assetId\": \"/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.MachineLearningServices/workspaces/$WORKSPACE/models/sklearn/versions/1\"
        },
        \"codeConfiguration\": {
            \"codeId\": \"/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.MachineLearningServices/workspaces/$WORKSPACE/codes/score-sklearn/versions/1\",
            \"scoringScript\": \"score.py\"
        },
        \"environmentId\": \"/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.MachineLearningServices/workspaces/$WORKSPACE/environments/sklearn-env\",
        \"InstanceType\": \"Standard_F2s_v2\"
    }
}")
#</create_deployment>

echo "Endpoint headers: $headers"
operation_id=$(echo $headers | grep -Fi azure-asyncoperation | sed "s/azure-asyncoperation: //" | tr -d '\r\\')
wait_for_completion $operation_id

# <get_endpoint>
response=$(curl --location --request GET "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.MachineLearningServices/workspaces/$WORKSPACE/onlineEndpoints/my-endpoint?api-version=$API_VERSION" \
--header "Content-Type: application/json" \
--header "Authorization: Bearer $TOKEN")

scoringUri=$(echo $response | jq -r ".properties" | jq -r ".scoringUri")
# </get_endpoint>

# <get_access_token>
response=$(curl -H "Content-Length: 0" --location --request POST "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.MachineLearningServices/workspaces/$WORKSPACE/onlineEndpoints/my-endpoint/token?api-version=$API_VERSION" \
--header "Authorization: Bearer $TOKEN")
accessToken=$(echo $response | jq -r ".accessToken")
# </get_access_token>

# <score_endpoint>
curl --location --request POST $scoringUri \
--header "Authorization: Bearer $accessToken" \
--header "Content-Type: application/json" \
--data-raw @endpoints/online/model-1/sample-request.json
# </score_endpoint>

# <get_deployment_logs>
curl --location --request POST "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.MachineLearningServices/workspaces/$WORKSPACE/onlineEndpoints/my-endpoint/deployments/blue/getLogs?api-version=$API_VERSION" \
--header "Authorization: Bearer $TOKEN" \
--header "Content-Type: application/json" \
--data-raw "{ \"tail\": 100 }"
#</get_deployment_logs>

# delete endpoint
curl --location --request DELETE "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.MachineLearningServices/workspaces/$WORKSPACE/onlineEndpoints/my-endpoint?api-version=$API_VERSION" \
--header "Content-Type: application/json" \
--header "Authorization: Bearer $TOKEN" || true
