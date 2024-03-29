import automox_console_sdk as automox
import os
import logging
import json
import argparse
import difflib
import sys


# Attempt to retrieve environment variables
ORG = os.getenv('AUTOMOX_ORG')
API_KEY = os.getenv('AUTOMOX_API_KEY')

# Check if either environment variable is not set
if ORG is None or API_KEY is None:
    print("Error: AUTOMOX_ORG and AUTOMOX_API_KEY environment variables must be set.")
    sys.exit(1)  # Exit with an error status code

CONFIG = automox.Configuration()

client = automox.ApiClient(configuration=CONFIG)
client.default_headers['Authorization'] = f"Bearer {API_KEY}"
policies_api = automox.PoliciesApi(client)
keys_to_ignore = ['uuid', 'id', 'organization_id', 'create_time', 'server_count']

# Initialize logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger()

#############################
#### Program Starts Here
#############################

def delete_dir_contents(path):
    """Recursively deletes the contents of a directory."""
    for filename in os.listdir(path):
        file_path = os.path.join(path, filename)
        if os.path.isfile(file_path) or os.path.islink(file_path):
            os.remove(file_path)  # Remove files and links
        elif os.path.isdir(file_path):
            delete_dir_contents(file_path)  # Recursively delete directory contents
            os.rmdir(file_path)  # Remove now-empty directory

def normalize_line_endings(s):
    """Normalize the line endings in a string to use Unix-style (\n)."""
    normalized = s.replace('\\r\\n', '\\n').replace('\\r', '\\n')
    return normalized


def remove_keys_from_dict(dict_obj, keys_to_remove):
    """Recursively remove keys from the dictionary."""
    modified_dict = {}
    for key, value in dict_obj.items():
        if key not in keys_to_remove:
            if isinstance(value, dict):
                modified_dict[key] = remove_keys_from_dict(value, keys_to_remove)
            else:
                modified_dict[key] = value
    return modified_dict

def rehydrate_scripts_for_diff(policy_dict, policy_name):
    """Temporarily rehydrates the scripts from disk for diffing, based on placeholders in the policy dictionary,
    and normalizes line endings."""
    policy_name = policy_name.lower().replace(" ", "_")
    folder_name = f"policies/{policy_name}"
    
    # Make a deep copy of the policy_dict to modify without affecting the original
    rehydrated_policy_dict = json.loads(json.dumps(policy_dict))

    configuration = rehydrated_policy_dict.get('configuration', {})
    script_keys = ['remediation_code', 'evaluation_code']

    for key in script_keys:
        script_filename = configuration.get(key)
        if script_filename:
            script_path = os.path.join(folder_name, script_filename)
            try:
                with open(script_path, 'r') as script_file:
                    script_content = script_file.read()
                    # Normalize line endings before replacing the placeholder
                    script_content_normalized = normalize_line_endings(script_content)
                # Replace the placeholder in the configuration with the normalized script content
                configuration[key] = script_content_normalized
            except FileNotFoundError:
                logger.error(f"Script file not found for {policy_name}: {script_filename}")
                # If the script file is missing, replace the placeholder with a note to indicate the issue
                configuration[key] = f"Error: Script file not found for {script_filename}"

    return rehydrated_policy_dict

def save_policy_and_scripts(policy_dict, policy_id, policy_name, run_mode):
    """Extracts scripts if conditions are met, saves them with the appropriate extension, 
    and handles saving policy states based on the run_mode."""
    logger.debug(f"Processing policy {policy_id} - {policy_name} for remote state.")
    policy_name = policy_name.lower().replace(" ", "_")
    folder_name_remote = f"state/{policy_name}"
    os.makedirs(folder_name_remote, exist_ok=True)

    # Always save the remote state as policy.json.remote for both modes
    remote_json_path = os.path.join(folder_name_remote, f"policy.json.remote.{ORG}")
    
    # Serialize policy_dict to JSON string and encode to bytes
    remote_policy = normalize_line_endings(json.dumps(policy_dict, sort_keys=True, indent=2))

    # Write the bytes with Unix line endings to file in binary mode
    with open(remote_json_path, 'w') as remote_json_file:
        remote_json_file.write(remote_policy)

    logger.debug(f"Saved remote state for policy {policy_id} - {policy_name}.")

    # If run_mode is 'full', proceed to process the policy for local state, including script handling
    if run_mode == "full":
        folder_name = f"policies/{policy_name}"
        os.makedirs(folder_name, exist_ok=True)
        os_family = policy_dict.get('configuration', {}).get('os_family')
        script_extension = ".sh" if os_family in ["Mac", "Linux"] else ".ps1"

        if policy_dict.get('policy_type_name') == 'custom' and script_extension:
            configuration = policy_dict.get('configuration', {})

            # Extract and save scripts, replace actual code with placeholders
            for key in ['remediation_code', 'evaluation_code']:
                if key in configuration:
                    script_filename = f"{key}{script_extension}"
                    script_path = os.path.join(folder_name, script_filename)
                    with open(script_path, 'w') as script_file:
                        script_file.write(configuration[key])
                    if script_extension == ".sh":
                        os.chmod(script_path, 0o755)  # Make shell scripts executable
                    configuration[key] = script_filename  # Update with placeholder

        # Save the modified policy dictionary as JSON (local state)
        policy_dict = remove_keys_from_dict(policy_dict, keys_to_ignore)
        local_policy_json = normalize_line_endings(json.dumps(policy_dict, sort_keys=True, indent=2))
        local_json_path = os.path.join(folder_name, "policy.json")
        with open(local_json_path, 'w') as local_json_file:
            local_json_file.write(local_policy_json)

    logger.debug(f"Completed processing for policy {policy_id} - {policy_name} in {run_mode} mode.")


def sync_policies(sync_mode, debug=False):
    """Pull the policies from the remote Automox API and update them on disk."""
    if debug:
        logger.setLevel(logging.DEBUG)

    state_dir = "state/"
    if os.path.exists(state_dir):
        delete_dir_contents(state_dir)  # Delete contents of the state directory
        os.rmdir(state_dir)  # Remove the now-empty state directory

    # Proceed with syncing policies
    for policy in policies_api.get_policies(o=ORG, limit=500, page=0):
        logger.debug(f"Processing policy {policy['id']}")
        save_policy_and_scripts(policy, policy['id'], policy['name'], sync_mode)

def diff_policies(debug=False, run_mode='normal'):
    """Compares local and remote policy states, logs differences, or returns a list of policies that need to be updated or created."""
    if debug:
        logger.setLevel(logging.DEBUG)

    # Ensure the local state is synced with the current remote state
    sync_policies(sync_mode="normal")

    policies_path = "policies/"
    state_path = "state/"
    policies_needing_update = []  # Initialize empty list to track policies needing updates
    policies_missing_remote = []  # Initialize empty list to track For policy creations

    local_policy_names = [d for d in os.listdir(policies_path) if os.path.isdir(os.path.join(policies_path, d))]
    remote_policy_names = [d for d in os.listdir(state_path) if os.path.isdir(os.path.join(state_path, d))]

    # Identify policies that exist locally but not remotely
    for policy_name in local_policy_names:
        if policy_name not in remote_policy_names:
            policies_missing_remote.append(policy_name)
            continue  # Skip the diff process for policies missing remotely

        local_json_path = os.path.join(policies_path, policy_name, "policy.json")
        remote_json_path = os.path.join(state_path, policy_name, f"policy.json.remote.{ORG}")

        try:
            with open(local_json_path, 'r') as local_file, open(remote_json_path, 'r') as remote_file:
                local_policy = json.load(local_file)
                remote_policy = json.load(remote_file)

            local_policy_rehydrated = rehydrate_scripts_for_diff(local_policy, policy_name)
            local_policy_rehydrated_cleaned = remove_keys_from_dict(local_policy_rehydrated, keys_to_ignore)
            remote_policy_cleaned = remove_keys_from_dict(remote_policy, keys_to_ignore)

            local_policy_str = json.dumps(local_policy_rehydrated_cleaned, sort_keys=True, indent=2)
            remote_policy_str = json.dumps(remote_policy_cleaned, sort_keys=True, indent=2)

            # Generate line-by-line diff
            diff = list(difflib.unified_diff(
                local_policy_str.splitlines(keepends=True),
                remote_policy_str.splitlines(keepends=True),
                fromfile="local",
                tofile="remote",
            ))

            if diff:
                if run_mode == 'normal':
                    logger.info(f"Policy {policy_name} differs between local and remote states (ignoring keys: {', '.join(keys_to_ignore)}):")
                    for line in diff:
                        logger.info(line.rstrip())
                elif run_mode == 'flag':
                    policies_needing_update.append(policy_name)
            else:
                logger.debug(f"Policy {policy_name} (ignoring keys: {', '.join(keys_to_ignore)}) is identical between local and remote states.")
        except FileNotFoundError:
            logger.error(f"Error accessing policy files for {policy_name}")
        
    if policies_missing_remote:
        for policy in policies_missing_remote:
            logger.info(f"Policy: {policy} exists in local but not remote states and needs created")

    if run_mode == 'flag':
        return policies_needing_update, policies_missing_remote

def update_policies(debug=False):
    """Updates policies by posting them to the Automox API."""
    policies_to_update = diff_policies(debug=debug, run_mode='flag')
    
    if debug:
        logger.setLevel(logging.DEBUG)
    
    for policy_name in policies_to_update[0]:
        logger.info(f"Starting update to policy {policy_name} in remote.")
        try:
            # Rehydrate the policy into its full form
            policy_path = f"policies/{policy_name}/policy.json"
            with open(policy_path, 'r') as policy_file:
                policy_data = json.load(policy_file)

            policy_state = f"state/{policy_name}/policy.json.remote." + str(ORG)
            with open(policy_state, 'r') as state_file:
                state_data = json.load(state_file)

            policy_id = state_data['id']
            # Rehydrate any scripts 
            policy_data_full = rehydrate_scripts_for_diff(policy_data, policy_name)
            policy_data_full['organization_id'] = ORG
            policy_data_full['id'] = policy_id
            policies_api.update_policy(policy_data_full, id=policy_id, o=ORG)
            sync_policies(sync_mode="normal")
            
            logger.info(f"Successfully updated policy {policy_name} in remote.")
        except Exception as e:
            logger.error(f"Error updating policy {policy_name}: {e}")
    for policy_name in policies_to_update[1]:
        logger.info(f"Starting create on policy {policy_name} in remote.")
        try:
            # Rehydrate the policy into its full form
            policy_path = f"policies/{policy_name}/policy.json"
            with open(policy_path, 'r') as policy_file:
                policy_data = json.load(policy_file)

            # Rehydrate any scripts 
            policy_data_full = rehydrate_scripts_for_diff(policy_data, policy_name)
            policy_data_full['organization_id'] = ORG
            policies_api.create_policy(body=policy_data_full, o=ORG)
            sync_policies(sync_mode="normal")
            
            logger.info(f"Successfully Created policy {policy_name} in remote.")
        except Exception as e:
            logger.error(f"Error creating policy {policy_name}: {e}")



def main():
    parser = argparse.ArgumentParser(description="Automox Policy Management Tool")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # Sync sub-command
    parser_sync = subparsers.add_parser("sync", help="Sync policies")
    parser_sync.add_argument("--mode", choices=["full", "normal"], default="normal", help="Sync mode: 'full' or 'normal'")
    parser_sync.add_argument("--debug", action="store_true", help="Enable debug logging")

    # Update sub-command
    parser_update = subparsers.add_parser("update", help="Update policies")
    parser_update.add_argument("--debug", action="store_true", help="Enable debug logging")

    # Diff sub-command
    parser_diff = subparsers.add_parser("diff", help="Diff policies")
    parser_diff.add_argument("--mode", choices=["flag", "normal"], default="normal", help="Diff mode: 'flag' or 'normal'")
    parser_diff.add_argument("--debug", action="store_true", help="Enable debug logging")

    args = parser.parse_args()

    if args.command == "sync":
        sync_policies(sync_mode=args.mode, debug=args.debug)
    elif args.command == "update":
        update_policies(debug=args.debug)
    elif args.command == "diff":
        diff_policies(run_mode=args.mode, debug=args.debug)

if __name__ == '__main__':
    main()
