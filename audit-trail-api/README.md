

## Setup

Prerequisites
- Python 3

### Steps

1. Clone this repository

2. Setup a virtual environment
```
cd automox-audit-log-collector
python3 -m venv venv
source venv/bin/activate
```

3. Install the required packages
```
pip install -r requirements.txt
```

4. Setup/Populate the .env file
```
cp .env.example .env
nano .env
```

5. Test the script and make sure it works!
```
python3 automox-audit-log-collector.py
```

If it worked, you should see a `cursor.txt` file in the same directory as the script. This file is used to keep track of the last time the script was run. 

You should also see the logs in the AWS S3 bucket you specified in the `.env` file.

6. Setup a cron job to run the script at your desired interval
```
crontab -e
```

You can use the following expression and change it to your needs:
```
*/5 * * * *  /Full/Path/To/venv/bin/python3 /Full/Path/To/Script/main.py >> /Full/Path/To/cron.log 2>&1
```

`*/5 * * * *` = The cron expression. In this case, we’re saying “run this every 5 minutes”.  If you want to run the script on a different cadence, check out https://crontab.cronhub.io/ to help you build a cron expression.

`/Full/Path/To/venv/bin/python3` = Where the `python 3` binary from your virtual environment lives on your system. You can find this in the `venv` folder under `venv/bin/python3`. It’s important to use this binary because the script relies on non-standard Python packages only available to our virtual environment.

`/Full/Path/To/main.py` = Where the script lives (where you cloned the repo to)

`>>` - This is simply instructing the system to redirect and append the output from the script to a file of your choosing

`/Full/Path/To/cron.log 2>&1` = Where you want to log the script’s operations. Because we included `2>&1`, both stdout and stderr will be logged. You can change this path to wherever you want to log the script’s output.

For reference, here is how it looks on our test VM:
```
*/5 * * * * /home/parallels/automox-audit-log-collector/venv/bin/python3 /home/parallels/automox-audit-log/main.py >> /home/parallels/automox-audit-log-collector/cron.log 2>&1
```

7. Profit!
If you made it this far, congratulations! You now have a script that will fetch the Automox audit logs and upload them to an S3 bucket on a recurring basis. You can now use these logs to ingest into your SIEM. [Here's an example on how to do this with Rapid7](https://docs.rapid7.com/insightidr/data-collection-methods/#aws-s3).