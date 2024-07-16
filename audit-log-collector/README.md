# Automox Audit Log Collector Script

This script fetches the audit logs from the [Automox Audit Trail API](https://developer.automox.com/openapi/audit-trail/overview/) and uploads them to an S3 bucket for your SIEM to ingest them. This script is designed to be run on a recurring basis via a cron job.

## Setup

Prerequisites
- `python3` installed on the system running the script

### Steps

**1\)** Clone this repository, run the `setup.sh` script and follow the on-screen instructions to modify the .env file
```
git clone https://github.com/AutomoxSecurity/automox-tools.git
cd automox-tools/audit-log-collector
./setup.sh
```

**2\)** Test the script and make sure it works!
```
python3 main.py
```

If it worked, you should see a `cursor.txt` file in the same directory as the script. This file is used to keep track of the last time the script was run. 

You should also see the logs in the AWS S3 bucket you specified in the `.env` file.

**3\)** Setup a cron job to run the script at your desired interval

You can do this manually or by running the `install.sh` script. The `install.sh` script will create a cron job that runs the script at every 10th minute from 9 through 59.


> [!WARNING]
> To ensure that the script is getting all of the logs, we recommend at a minimum running the cron at the end of each day at 11:59 PM. This is especially important because the script will grab logs for the current date of the time it is run. If we set our cron to run at the top of every hour, when it runs at 11PM on 7/16/2024, there’s a possibility that we’ll miss the logs between 11PM and 12AM the next day.
> 
> A safe bet is to run the script every 10 minutes like so:
> 9-59/10 * * * *


**4\)** Profit!
If you made it this far, congratulations! You now have a script that will fetch the Automox audit logs and upload them to an S3 bucket on a recurring basis. You can now use these logs to ingest into your SIEM. [Here's an example on how to do this with Rapid7](https://docs.rapid7.com/insightidr/data-collection-methods/#aws-s3).