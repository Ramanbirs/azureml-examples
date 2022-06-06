#!/bin/bash

# <az_ml_sdk_install>
pip install --pre azure-ai-ml
# </az_ml_sdk_install>

# <mldesigner_install>
pip install mldesigner
# </mldesigner_install>

# <az_ml_sdk_test_install>
pip install azure-ai-ml==0.1.0b4 --extra-index-url https://azuremlsdktestpypi.azureedge.net/sdk-v2-public-candidate
# </az_ml_sdk_test_install>

pip list
