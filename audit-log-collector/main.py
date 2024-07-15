import requests
import os
import json
import boto3
import pathlib

from dotenv import load_dotenv
from datetime import datetime
from botocore.exceptions import BotoCoreError, ClientError

# This script is designed to be run from a Cron Job

# Load environment variables from .env file
load_dotenv()

#####
# Use an env file or manually set me (not recommended)
#####
org_uuid = os.getenv("AUTOMOX_ORG_UUID")
api_key = os.getenv("AUTOMOX_API_KEY")
s3_bucket = os.getenv("AWS_S3_BUCKET") 
aws_region = os.getenv("AWS_REGION")

url = f"https://console.automox.com/api/audit-service/v1/orgs/{org_uuid}/events"
cursor_file = pathlib.Path(__file__).parent / "cursor.txt"
current_date = datetime.now().strftime("%Y-%m-%d")


def fetch_audit_logs(url, api_key, date, cursor=None, limit=None):
    print("Fetching logs from the Automox Audit Trail API...")

    query = {
        "date": date,
        "cursor": cursor,
        "limit": limit
    }

    headers = {
        "Authorization": f"Bearer {api_key}"
    }

    response = requests.get(url, headers=headers, params=query)
    
    # Check for errors
    if response.status_code != 200:
        print(f"Error: {response.status_code} + {response.text}")
        return None, None

    data = response.json()

    # Check if there are any new logs since last pull
    if data['metadata']['count'] == 0:
        print("No new logs were found since last pull...Exiting.")
        return None, None

    # Set the cursor to the last log id
    new_cursor = data['data'][-1]['id']

    return data, new_cursor
    

def send_to_s3(data):
    s3 = boto3.client('s3')
    try:
        print("Uploading logs to S3...")
        s3.put_object(Bucket=s3_bucket, Key=f"automox-audit-logs-{datetime.now().strftime('%Y-%m-%d-%H-%M-%S')}.json", Body=json.dumps(data))
        print("Upload complete!")
    except (BotoCoreError, ClientError) as error:
        print(f"Failed to upload logs to S3: {error}")


def save_last_cursor(cursor):
    try:
        with open(cursor_file, 'w+') as file:
            file.write(cursor)
    except Exception as error:
        print(f"Failed to save cursor: {error}")


def read_last_cursor():
    try:
        with open(cursor_file, 'r') as file:
            return file.read().strip()
    except FileNotFoundError:
        print("Cursor file not found.")
        return None


def main():
    print(f"Script start: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    last_cursor = read_last_cursor()
    data, new_cursor = fetch_audit_logs(url, api_key, current_date, cursor=last_cursor)
    
    if data:
        send_to_s3(data)
        save_last_cursor(new_cursor)

if __name__ == "__main__":
    main()