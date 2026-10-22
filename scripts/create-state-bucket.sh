#!/usr/bin/env bash

set -euo pipefail

BUCKET=llm-platform-terraform-state-$(openssl rand -hex 8)

# aws help -> aws s3 help (not the one I was looking for) -> aws s3api help

# aws s3api help -> aws s3api create-bucket help
aws s3api create-bucket --profile admin --region eu-central-1 --bucket "$BUCKET" \
  --create-bucket-configuration LocationConstraint=eu-central-1 && echo "$BUCKET created."

# aws s3api help -> aws s3api put-bucket-versioning help
aws s3api put-bucket-versioning --profile admin --region eu-central-1 \
  --bucket "$BUCKET" --versioning-configuration Status=Enabled && echo "Versioning enabled."

# aws s3api help | grep public -> aws s3api put-public-access-block help
aws s3api put-public-access-block --profile admin --region eu-central-1 \
  --bucket "$BUCKET" --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true && echo "Public access blocked."
