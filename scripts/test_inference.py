"""
================================================================================
END-TO-END AI INFERENCE TEST SCRIPT (test_inference.py)
================================================================================
Why do we need this script?
This script proves that every layer of your elastic AWS AI platform works
together seamlessly—from your laptop all the way down to the NVIDIA GPU:
  1. Logs into AWS Cognito (either reusing a token you already exported via
     `get_token.sh`, or logging in directly with your demo email & password)
     to obtain a temporary security pass (JWT token).
  2. Connects the official Python `OpenAI` client library to your custom AWS
     API Gateway endpoint instead of OpenAI's servers.
  3. Queries `/v1/models` to verify that the vLLM Router sees your live
     `llama-3.1-8b` GPU worker.
  4. Sends a real prompt and streams back the AI's answer word-by-word in real
     time, passing an `x-session-id` header for session tracking.
================================================================================
"""

import os          # Reads environment variables (like AWS_DEFAULT_REGION, OPENAI_API_KEY)
import subprocess  # Lets Python run terminal commands (used here to read Terraform outputs)
import boto3       # Official AWS SDK for Python (used to log into AWS Cognito)
from openai import OpenAI  # Official OpenAI Python library (works with any vLLM endpoint!)


def get_tf_output(key: str) -> str:
    """
    Helper Function: Reads a specific output value from your `terraform/` folder.
    Instead of forcing you to copy-paste long AWS URLs or Client IDs by hand,
    this runs `terraform -chdir=terraform output -raw <key>` behind the scenes.
    """
    return subprocess.check_output(
        ["terraform", "-chdir=terraform", "output", "-raw", key],
        text=True,  # Return the result as a clean Python string instead of raw bytes
    ).strip()       # Remove any trailing newline characters


def main():
    # --------------------------------------------------------------------------
    # Step 1: Load Endpoint URL & Check for Existing Login Token
    # --------------------------------------------------------------------------
    # Default to "us-east-1" unless AWS_DEFAULT_REGION was set in your `.env` file
    region = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")

    # Use OPENAI_API_BASE if already exported in your terminal; otherwise fetch
    # the live public API Gateway URL directly from Terraform outputs
    api_base = os.environ.get("OPENAI_API_BASE") or get_tf_output("openai_api_base_url")

    # Check if you already ran `eval "$(./scripts/get_token.sh)"` to set OPENAI_API_KEY
    jwt_token = os.environ.get("OPENAI_API_KEY")

    # --------------------------------------------------------------------------
    # Step 2: Automatic Cognito Login Fallback (If No Token Was Pre-Exported)
    # --------------------------------------------------------------------------
    # If `OPENAI_API_KEY` isn't already set in your shell, this block logs into
    # AWS Cognito automatically using your demo user's email and password from `.env`.
    if not jwt_token:
        # Look up the public User App Client ID created by Terraform
        client_id = get_tf_output("cognito_user_client_id")

        # Read the demo user's login credentials from your environment variables
        username = os.environ["TF_VAR_demo_user_email"]
        password = os.environ["TF_VAR_demo_user_password"]

        # Create an AWS Cognito client and exchange the email + password for a JWT pass
        cognito = boto3.client("cognito-idp", region_name=region)
        auth_response = cognito.initiate_auth(
            AuthFlow="USER_PASSWORD_AUTH",
            ClientId=client_id,
            AuthParameters={
                "USERNAME": username,
                "PASSWORD": password,
            },
        )
        # Extract the Identity Token (JWT) that API Gateway expects in Authorization headers
        jwt_token = auth_response["AuthenticationResult"]["IdToken"]

    # --------------------------------------------------------------------------
    # Step 3: Initialize the OpenAI SDK Pointing to Your Private AWS Endpoint
    # --------------------------------------------------------------------------
    # Because vLLM implements the exact same REST API standard as OpenAI, you
    # don't need custom client code—just swap `base_url` to your API Gateway URL
    # and pass your Cognito JWT token as `api_key`.
    client = OpenAI(base_url=api_base, api_key=jwt_token)

    # --------------------------------------------------------------------------
    # Step 4: Discover Available AI Models (`GET /v1/models`)
    # --------------------------------------------------------------------------
    # Asks the vLLM Router which models are currently registered and healthy.
    # You should see `['llama-3.1-8b']` printed in your terminal.
    models = [m.id for m in client.models.list().data]
    print("Available models:", models)

    # --------------------------------------------------------------------------
    # Step 5: Send a Streaming Chat Completion Request (`POST /v1/chat/completions`)
    # --------------------------------------------------------------------------
    # Sends a prompt to `llama-3.1-8b` and streams tokens back as they are generated
    # on the GPU rather than waiting for the entire paragraph to finish first.
    stream = client.chat.completions.create(
        model="llama-3.1-8b",  # Must match `--served-model-name` in `vllm-llama3.yaml`
        messages=[
            # System message sets the AI's behavior and tone
            {"role": "system", "content": "You are a concise technical assistant."},
            # User message is the actual question sent to the model
            {
                "role": "user",
                "content": "Give three bullet points on why AWQ quantization fits 8B models onto a 16GB T4 GPU.",
            },
        ],
        temperature=0.2,  # Low temperature (0.0–1.0) keeps answers focused and factual
        max_tokens=200,   # Cap the response length at 200 tokens (~150 words)
        stream=True,      # Stream words live as the GPU generates each token

        # Custom Session Header:
        # When the vLLM Router runs in `session` routing mode, this header pins
        # follow-up messages from "llama-sdk-session-01" to the same GPU pod so
        # it can reuse cached conversation context (KV-cache) for faster replies.
        extra_headers={"x-session-id": "llama-sdk-session-01"},
    )

    # --------------------------------------------------------------------------
    # Step 6: Print Streamed Tokens Live to the Console
    # --------------------------------------------------------------------------
    # Loop through each tiny piece ("chunk") arriving over the network and print
    # it immediately (`flush=True` prevents Python from buffering text until newline).
    for chunk in stream:
        content = chunk.choices[0].delta.content
        if content:
            print(content, end="", flush=True)
    print()  # Print a final clean newline once generation finishes


# Standard Python entry point: only run `main()` when executed directly as a script
if __name__ == "__main__":
    main()