import os
import subprocess
import boto3
from openai import OpenAI


def get_tf_output(key: str) -> str:
    return subprocess.check_output(
        ["terraform", "-chdir=terraform", "output", "-raw", key],
        text=True,
    ).strip()


def main():
    region = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
    api_base = os.environ.get("OPENAI_API_BASE") or get_tf_output("openai_api_base_url")
    jwt_token = os.environ.get("OPENAI_API_KEY")

    # Authenticate via Cognito if OPENAI_API_KEY is not already exported
    if not jwt_token:
        client_id = get_tf_output("cognito_user_client_id")
        username = os.environ["TF_VAR_demo_user_email"]
        password = os.environ["TF_VAR_demo_user_password"]

        cognito = boto3.client("cognito-idp", region_name=region)
        auth_response = cognito.initiate_auth(
            AuthFlow="USER_PASSWORD_AUTH",
            ClientId=client_id,
            AuthParameters={
                "USERNAME": username,
                "PASSWORD": password,
            },
        )
        jwt_token = auth_response["AuthenticationResult"]["IdToken"]

    # Initialize OpenAI client pointing to API Gateway
    client = OpenAI(base_url=api_base, api_key=jwt_token)

    # Verify available models
    models = [m.id for m in client.models.list().data]
    print("Available models:", models)

    # Stream a completion from llama-3.1-8b
    stream = client.chat.completions.create(
        model="llama-3.1-8b",
        messages=[
            {"role": "system", "content": "You are a concise technical assistant."},
            {
                "role": "user",
                "content": "Give three bullet points on why AWQ quantization fits 8B models onto a 16GB T4 GPU.",
            },
        ],
        temperature=0.2,
        max_tokens=200,
        stream=True,
        extra_headers={"x-session-id": "llama-sdk-session-01"},
    )

    for chunk in stream:
        content = chunk.choices[0].delta.content
        if content:
            print(content, end="", flush=True)
    print()


if __name__ == "__main__":
    main()