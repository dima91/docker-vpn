# Docker OpenVPN Server

A simple and easy-to-use OpenVPN server running inside a Docker container, with helper scripts for client management.

This project provides a straightforward way to set up a personal or small-team VPN server using Docker.

## Features

- **Dockerized**: Runs OpenVPN in an isolated Docker container for easy deployment and management.
- **Easy Client Management**: Includes a simple shell script to generate and revoke client certificates and configuration files.
- **Secure Defaults**: Generates `.ovpn` profiles with a modern cipher (AES-256-GCM) and all necessary keys embedded for convenience.
- **Automatic IP Detection**: Automatically detects the server's public IP address for client configuration.

## Prerequisites

-   Docker
-   Docker Compose (recommended for easy management)

## Quick Start

1.  **Clone the repository:**
    ```sh
    git clone <repository-url>
    cd docker-vpn
    ```

2.  **Configure Environment Variables (Optional):**
    The server can automatically detect its public IP. However, for reliability, you can create a `.env` file in the project root to specify it.

    ```env
    # .env
    PUBLIC_IP=your.server.ip.address

    # Optional: Change VPN port and protocol
    # VPN_PORT=1194
    # VPN_PROTO=udp
    ```

3.  **Start the VPN Server:**
    *(This step assumes you have a `docker-compose.yml` file to build and run the container. You may need to run a one-time initialization command to generate server certificates first.)*

    ```sh
    docker-compose up -d
    ```

## Usage

Client management is handled by the `manage.sh` script located inside the `openvpn` container. You can execute it using `docker-compose exec`.

### Generating a new client

To create a new client configuration, run the following command. Replace `my-client` with your desired client name.

```sh
docker-compose exec openvpn bash /etc/openvpn/manage.sh gen-client my-client
```

This will generate a `my-client.ovpn` file inside the container's OpenVPN directory (e.g., `/etc/openvpn/`). If you have mapped this directory to a local volume, you can access the file directly on your host machine.

### Revoking a client

To revoke an existing client's access, run:

```sh
docker-compose exec openvpn bash /etc/openvpn/manage.sh revoke-client my-client
```

This revokes the client's certificate and updates the Certificate Revocation List (CRL). The OpenVPN server will automatically pick up the change and deny future connections from this client.

## Configuration

The `manage.sh` script uses the following environment variables when generating client profiles:

| Variable    | Description                                                                                             | Default                                      |
| :---------- | :------------------------------------------------------------------------------------------------------ | :------------------------------------------- |
| `PUBLIC_IP` | The public IP address or domain name of your server.                                                    | Auto-detected via `curl -s https://ifconfig.me` |
| `VPN_PORT`  | The port on which the VPN server will listen.                                                           | `1194`                                       |
| `VPN_PROTO` | The protocol the VPN server will use.                                                                   | `udp`                                        |
| `OPENVPN`   | Path to the OpenVPN data directory inside the container, where configs and keys are stored.             | (e.g., `/etc/openvpn`)                       |