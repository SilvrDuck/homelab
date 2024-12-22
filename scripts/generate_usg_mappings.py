#!/usr/bin/env python3
import sys
import os
import yaml
import socket

def get_self_ip():
    """
    Get the IP address of the current machine.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect(("8.8.8.8", 80))
    ip = s.getsockname()[0]
    s.close()
    return ip

def parse_compose_file(compose_file):
    """
    Parse a Docker Compose file and print a line for each service:
      set system static-host-mapping host-name <service>.lan inet <IP>
    """
    try:
        with open(compose_file, 'r') as f:
            compose_data = yaml.safe_load(f)
    except Exception as e:
        print(f"Error reading '{compose_file}': {e}")
        return

    services = compose_data.get('services', {})
    if not services:
        return

    # You can adjust these if you want a different domain
    domain_suffix = 'lan'
    self_ip = get_self_ip()

    for service_name in services.keys():
        print(f"set system static-host-mapping host-name {service_name}.{domain_suffix} inet {self_ip}")

def main():
    # Search for all "compose.yaml" files in the current directory and subdirectories
    compose_files = []
    for root, _, files in os.walk('.'):
        for file in files:
            if file == 'compose.yaml':
                compose_files.append(os.path.join(root, file))

    if not compose_files:
        print("No 'compose.yaml' files found.")
        sys.exit(1)

    # Process each found compose.yaml file
    for compose_file in compose_files:
        parse_compose_file(compose_file)

if __name__ == "__main__":
    main()
