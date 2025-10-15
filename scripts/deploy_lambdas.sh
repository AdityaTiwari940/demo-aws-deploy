#!/bin/bash
set -e

REGION="${AWS_DEFAULT_REGION:-us-west-2}"
ROLE_ARN="${LAMBDA_EXEC_ROLE_ARN}"   # IAM role ARN passed via environment variable
RUNTIME="python3.9"
HANDLER="lambda_function.lambda_handler"
LAMBDA_ALIAS="${LAMBDA_ALIAS:-live}"

mkdir -p build
APP_RESOURCES=""

echo "===== Starting Lambda Deployment in region $REGION ====="

for d in lambda/*/ ; do
  func_dir="${d%/}"
  func_name=$(basename "$func_dir")
  echo ">>> Processing Lambda: $func_name"

  # Install dependencies if present
  if [ -f "$func_dir/requirements.txt" ]; then
    echo "Installing dependencies for $func_name"
    pip install -r "$func_dir/requirements.txt" -t "$func_dir"
  fi

  # Zip the function
  zip_file="build/${func_name}.zip"
  (cd "$func_dir" && zip -r "../../$zip_file" . >/dev/null)
  echo "Zipped -> $zip_file"

  # Check if Lambda exists
  if ! aws lambda get-function --function-name "$func_name" --region "$REGION" >/dev/null 2>&1; then
    echo "Lambda $func_name does not exist. Creating..."
    aws lambda create-function \
      --function-name "$func_name" \
      --runtime "$RUNTIME" \
      --role "$ROLE_ARN" \
      --handler "$HANDLER" \
      --zip-file "fileb://$zip_file" \
      --region "$REGION" \
      --timeout 900 \
      --memory-size 512 >/tmp/create_${func_name}.json
  else
    echo "Updating existing Lambda: $func_name"
    aws lambda update-function-code \
      --function-name "$func_name" \
      --zip-file "fileb://$zip_file" \
      --region "$REGION" >/tmp/update_${func_name}.json
  fi

  # Publish new version
  NEW_VER=$(aws lambda publish-version \
              --function-name "$func_name" \
              --region "$REGION" \
              --query "Version" \
              --output text)
  echo "Published $func_name -> version $NEW_VER"

  # Ensure alias exists
  if ! aws lambda get-alias \
        --function-name "$func_name" \
        --name "$LAMBDA_ALIAS" \
        --region "$REGION" >/dev/null 2>&1; then
    echo "Creating alias $LAMBDA_ALIAS for $func_name -> $NEW_VER"
    aws lambda create-alias \
      --function-name "$func_name" \
      --name "$LAMBDA_ALIAS" \
      --function-version "$NEW_VER" \
      --region "$REGION" >/dev/null
  else
    echo "Updating alias $LAMBDA_ALIAS -> $NEW_VER for $func_name"
    aws lambda update-alias \
      --function-name "$func_name" \
      --name "$LAMBDA_ALIAS" \
      --function-version "$NEW_VER" \
      --region "$REGION" >/dev/null
  fi

  # Get alias current version
  ALIAS_CUR=$(aws lambda get-alias \
                 --function-name "$func_name" \
                 --name "$LAMBDA_ALIAS" \
                 --region "$REGION" \
                 --query "FunctionVersion" \
                 --output text)

  # Append to appspec.yml resource section
  APP_RESOURCES="${APP_RESOURCES}\n  - ${func_name}:\n      Type: AWS::Lambda::Function\n      Properties:\n        Name: ${func_name}\n        Alias: ${LAMBDA_ALIAS}\n        CurrentVersion: ${ALIAS_CUR}\n        TargetVersion: ${NEW_VER}\n"
done

# Generate appspec.yml for CodeDeploy
echo -e "version: 0.0\nResources:" > appspec.yml
echo -e "$APP_RESOURCES" >> appspec.yml

echo "===== Final appspec.yml ====="
cat appspec.yml
