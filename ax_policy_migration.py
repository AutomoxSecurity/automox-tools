#!/usr/bin/env python3

from pprint import pprint
import requests
import os

#===========================================================#
# HEADER_VALUES                                             #
#===========================================================#

# Current org environment variables
AX_API_TOKEN = os.environ.get("AX_API_TOKEN")
AX = "https://console.automox.com/api"
AX_HEADERS = {
    "Accept": "application/json",
    "Content-Type": "application/json",
    "Authorization": f"Bearer {AX_API_TOKEN}",
}

# New org environment variables
AX_API_TOKEN_2 = os.environ.get("AX_API_TOKEN_2")
AX_HEADERS_2 = {
    "Accept": "application/json",
    "Content-Type": "application/json",
    "Authorization": f"Bearer {AX_API_TOKEN_2}",
}

#======================================================================================================================#
# SCRIPT_INFO                                                                                                          #
# This script was built to migrate policies from one Automox org to another.  It will only move policies that are not  #
# currently in the new org.  If it detects a policy with the same name it will give a 400 response.  Response code 201 #
# means it successfully moved a policy                                                                                 #
#                                                                                                                      #
# Author: Ryan Braunstein                                                                                              #
# Company: Automox, Inc.                                                                                               #
# Version: 1.0                                                                                                         #
# Version Notes: Be the first to update this section!!!                                                                #
#======================================================================================================================#

# Retrieves all policy ID numbers from the current org
def retrieve_all_policy_ids():
    policy_ids = []
    query = {
    "o": "Current Org ID",
    "page": "0",
    "limit": "500"
    }
    #Cycles through the policy IDs and adds them to a list
    ax_policies = requests.get(f"{AX}/policies", headers=AX_HEADERS, params=query)
    data = ax_policies.json()
    for policy in data:
        policy_ids.append(policy['id'])

    return policy_ids

# Runs through the list of policies, formats them, and POSTs them to the new Org
def list_specific_policy(policy_ids):
    query = {
        "o": "Current Org ID"
    }
    for id in policy_ids:
        ax_policies = requests.get(f"{AX}/policies/{id}", headers=AX_HEADERS, params=query)
        data = ax_policies.json()
        query2 = {
        "o": "New Org ID"
        }
        # Formats all relevant info for the current org to be POSTed to the new org
        body = {
        "name": data['name'],
        "policy_type_name": data['policy_type_name'],
        "organization_id": 'New Org ID',
        "schedule_days": data['schedule_days'],
        "schedule_weeks_of_month": data['schedule_weeks_of_month'],
        "schedule_months": data['schedule_months'],
        "schedule_time": data['schedule_time'],
        "configuration": data['configuration']
        }
        ax_policies_post = requests.post(f"{AX}/policies", json=body, headers=AX_HEADERS_2, params=query2)
        pprint(ax_policies_post)

if __name__ == "__main__":
    policies = retrieve_all_policy_ids()
    list_specific_policy(policies)