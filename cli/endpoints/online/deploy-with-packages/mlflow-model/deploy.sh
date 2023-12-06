#<register_model>
MODEL_NAME='heart-classifier-mlflow'
MODEL_PATH='model'
az ml model create --name $MODEL_NAME --path $MODEL_PATH --type mlflow_model
#</register_model>

#<model_version>
MODEL_VERSION=$(az ml model show --name $MODEL_NAME --label latest | jq -r .version)
#</model_version>

#<build_package>
az ml model package --name $MODEL_NAME --version $MODEL_VERSION --file package.yml
#</build_package>

#<endpoint_name>
ENDPOINT_NAME="heart-classifier"
#</endpoint_name>

# The following code ensures the created deployment has a unique name
ENDPOINT_SUFIX=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${1:-5} | head -n 1)
ENDPOINT_NAME="$ENDPOINT_NAME-$ENDPOINT_SUFIX"

#<create_endpoint>
az ml online-endpoint create -n $ENDPOINT_NAME
#</create_endpoint>

#<create_deployment>
az ml online-deployment create -f deployment.yml -e $ENDPOINT_NAME
#</create_deployment>

#<test_deployment>
az ml online-endpoint invoke --name $ENDPOINT_NAME --deployment with-package -r sample-request.json
#</test_deployment>

#<create_deployment_inline>
az ml online-deployment create -f model-deployment.yml -e $ENDPOINT_NAME
#</create_deployment_inline>

#<delete_resources>
az ml online-endpoint delete -n $ENDPOINT_NAME --yes
#</delete_resources>

#<build_package_copy>
az ml model package --name $MODEL_NAME --version $MODEL_VERSION --file package-external.yml
#</build_package_copy>