#!/bin/bash

# Setup venv and install requirements
echo "Setting up virtual environment..."
python3 -m venv venv
if [ $? -ne 0 ]; then
    echo "Failed to create a virtual environment. Please ensure Python 3 and venv are correctly installed."
    exit 1
fi
source venv/bin/activate
pip install -r requirements.txt

# Copy the example env
cp example.env .env
echo -e "\nSetup script finished! Open your preferred text editor and modify $(pwd)/.env to fill in the variables"