BASE_PATH=endpoints/online/custom-container/r
ENDPOINT_NAME=r-endpoint
DEPLOYMENT_NAME=r-deployment

# Download model
wget https://aka.ms/r-model -O $BASE_PATH/scripts/model.rds

# Get name of workspace ACR, build image
WORKSPACE=$(az config get --query "defaults[?name == 'workspace'].value" -o tsv)
ACR_NAME=$(az ml workspace show --workspace-name $WORKSPACE --query container_registry -o tsv | cut -d'/' -f9-)

if [[$ACR_NAME==""]]
then
    echo "Getting ACR name failed, exiting"
    exit 1
fi

az acr login -n $ACR_NAME
IMAGE_TAG=${ACR_NAME}.azurecr.io/r_server
az acr build $BASE_PATH -f $BASE_PATH/Dockerfile -t $IMAGE_TAG -r $ACR_NAME

# Clean up utility
cleanup(){
    sed -i 's/'$ACR_NAME'/{{acr_name}}/' $BASE_PATH/$DEPLOYMENT_NAME.yml
    echo "deleting endpoint, state is "$STATE
    az ml online-endpoint delete -n $ENDPOINT_NAME
    az ml model delete --name plumber --version 1
    az ml environment delete --name r-environment --version 1
}

# Run image locally for testing
docker run --rm -d -p 8000:8000 \
    -v $PWD/$BASE_PATH/scripts:/var/azureml-app/azureml-models/plumber/1/scripts \
    --name="r_server" $IMAGE_TAG

sleep 10

# Check liveness, readiness, scoring locally
curl "http://localhost:8000/live"
curl "http://localhost:8000/ready"
curl -H "Content-Type: application/json" --data @$BASE_PATH/sample_request.json http://localhost:8000/score

docker stop r_server

# Fill in placeholders in deployment YAML
sed -i 's/{{acr_name}}/'$ACR_NAME'/' $BASE_PATH/$DEPLOYMENT_NAME.yml

EXISTS=$(az ml online-endpoint show -n $ENDPOINT_NAME --query name -o tsv)
# Update endpoint if exists, else create
if [[ $EXISTS == $ENDPOINT_NAME ]]
then 
  STATE=$(az ml online-endpoint show -n $ENDPOINT_NAME --query deployments[0].provisioning_state -o tsv)
  az ml online-endpoint update -f $BASE_PATH/$ENDPOINT_NAME.yml
else
  az ml online-endpoint create -f $BASE_PATH/$ENDPOINT_NAME.yml
fi

# check if create was successful
endpoint_status=`az ml online-endpoint show --name $ENDPOINT_NAME --query "provisioning_state" -o tsv`
echo $endpoint_status
if [[ $endpoint_status == "Succeeded" ]]
then
  echo "Endpoint created successfully"
else
  echo "Endpoint creation failed"
  az ml online-endpoint delete --name $ENDPOINT_NAME
  exit 1
fi

# Create deployment 
az ml online-deployment create --name $DEPLOYMENT_NAME --endpoint $ENDPOINT_NAME --file $BASE_PATH/$DEPLOYMENT_NAME.yml --all-traffic

# <get_status>
az ml online-endpoint show -n $ENDPOINT_NAME
# </get_status>

deploy_status=`az ml online-deployment show --name $DEPLOYMENT_NAME --endpoint $ENDPOINT_NAME --query "provisioning_state" -o tsv`
echo $deploy_status
if [[ $deploy_status == "Succeeded" ]]
then
  echo "Deployment completed successfully"
else
  echo "Deployment failed"
  cleanup 
  exit 1
fi

# Test remotely
echo "Testing endpoint"
for i in {1..10}
do
   RESPONSE=$(az ml online-endpoint invoke -n $ENDPOINT_NAME --request-file $BASE_PATH/sample_request.json)
done

echo "Tested successfully, response was $RESPONSE. Cleaning up..."

# Clean up
cleanup
