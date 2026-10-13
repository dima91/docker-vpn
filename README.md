# Docker OpenVPN Server

A simple and easy-to-use OpenVPN server running inside a Docker container, with helper scripts for client management.

This project provides a straightforward way to set up a personal or small-team VPN server using Docker.

## Features

- **Dockerized**: Runs OpenVPN in an isolated Docker container for easy deployment and management.
- **Easy Client Management**: Includes a simple shell script to generate and revoke client certificates and configuration files.
- **Secure Defaults**: Generates `.ovpn` profiles with a modern cipher (AES-256-GCM) and all necessary keys embedded for convenience. Revoked certificates are refused, and IPv6 traffic is kept from leaking around the tunnel.
- **Automatic IP Detection**: Automatically detects the server's public IP address for client configuration.
- **Multi-architecture image**: Published for `linux/amd64`, `linux/arm64` and `linux/arm/v7`.

## Prerequisites

-   Docker
-   Docker Compose v2 (the `docker compose` command)

## Quick Start

1.  **Clone the repository:**
    ```sh
    git clone <repository-url>
    cd docker-vpn/sample
    ```

    The `sample` directory contains a `docker-compose.yml` that runs two independent VPN servers, `vpn-personal` (UDP port 1194) and `vpn-work` (UDP port 1195). Remove the one you do not need.

2.  **Configure Environment Variables (Optional):**
    The server can automatically detect its public IP. However, for reliability, you can create a `.env` file in the `sample` directory, next to `docker-compose.yml`, to specify it.

    ```env
    # sample/.env
    PUBLIC_IP=your.server.ip.address

    # Optional: change the VPN protocol
    # VPN_PROTO=udp

    # Optional: use another image, for example the one published by your fork
    # VPN_IMAGE=your-user/docker-vpn:1.0.0
    ```

    Ports and subnets are set per service in `docker-compose.yml`.

3.  **Start the VPN Server:**

    ```sh
    docker compose up -d
    ```

    The image is pulled from Docker Hub. If it cannot be pulled, it is built from the `docker` directory instead. On the first start each server creates its certificates, which can take a minute or two; follow it with `docker compose logs -f` and wait for `Initialization Sequence Completed`.

    Each server keeps its data, including the private key of its certificate authority, in `sample/data/<name>`. Keep that directory private and back it up: it is ignored by git on purpose.

## Usage

Client management is handled by the `manage.sh` script inside each container. You can execute it using `docker compose exec` with the name of the service, from the `sample` directory.

### Generating a new client

To create a new client configuration, run the following command. Replace `my-client` with your desired client name.

```sh
docker compose exec vpn-personal manage.sh gen-client my-client
```

This generates `my-client.ovpn` in the server's data directory, which is `sample/data/personal/my-client.ovpn` on the host. The file contains the client's private key, so hand it over through a secure channel.

The client certificate is valid for 825 days. To choose another validity, add the number of days; `0` means the maximum, 3650 days:

```sh
docker compose exec vpn-personal manage.sh gen-client my-client 365
```

To renew a client, revoke it and generate it again with the same name.

### Revoking a client

To revoke an existing client's access, run:

```sh
docker compose exec vpn-personal manage.sh revoke-client my-client
```

This revokes the client's certificate and updates the Certificate Revocation List (CRL). The OpenVPN server picks up the change by itself and refuses every new connection from this client.

A client that is connected at that moment keeps its current session. To disconnect it right away, restart the server:

```sh
docker compose restart vpn-personal
```

## Configuration

The containers are configured through environment variables, set in the `environment` section of `docker-compose.yml`:

| Variable         | Description                                                                                          | Default                                         |
| :--------------- | :--------------------------------------------------------------------------------------------------- | :---------------------------------------------- |
| `PUBLIC_IP`      | The public IP address or domain name of your server, written into the client profiles.               | Auto-detected via `curl https://ifconfig.me`    |
| `VPN_PORT`       | The port on which the VPN server listens. Must match the port published by the service.              | `1194`                                          |
| `VPN_PROTO`      | The protocol the VPN server uses, `udp` or `tcp`.                                                    | `udp`                                           |
| `VPN_SUBNET`     | The `/24` network handed out to the clients. Use a different one for each server.                    | `10.8.0.0`                                      |
| `VPN_BLOCK_IPV6` | Set to `0` to stop blocking the clients' IPv6 traffic (see below).                                   | `1`                                             |
| `OPENVPN`        | Path to the OpenVPN data directory inside the container, where configs and keys are stored.          | `/etc/openvpn`                                  |

`server.conf` is written again from these variables every time the container starts, so a changed value takes effect with `docker compose up -d`. Manual edits to `server.conf` are overwritten. Profiles already handed out keep the address, port and protocol they were generated with: after changing one of those, generate the clients again.

`VPN_IMAGE` is read by `docker-compose.yml` itself and selects the image to run.

### IPv6

The tunnel carries IPv4 only. So that a client with IPv6 connectivity does not keep reaching IPv6 sites outside the VPN, the server tells clients to route IPv6 into the tunnel and reject it there. Applications then fall back to IPv4.

A client whose operating system has IPv6 disabled cannot apply this and fails to connect with `Linux can't add IPv6 to interface tun0`. Either add this line to that client's `.ovpn` file:

```text
pull-filter ignore "ifconfig-ipv6"
```

or set `VPN_BLOCK_IPV6=0` on the server, which turns the protection off for all its clients.

### Certificates

The certificate authority and the server certificate are valid for 10 years. A server certificate that is about to expire is renewed when the container starts, and client profiles keep working after that. When the certificate authority itself expires, the data directory has to be created again together with all client profiles.

## Image tags

The image is published to Docker Hub as `dockerdima/docker-vpn` whenever the `docker` directory changes on `main`:

| Tag            | Meaning                                                                        |
| :------------- | :----------------------------------------------------------------------------- |
| `latest`       | The most recent build of `main`. It changes over time.                         |
| `sha-<commit>` | The build of one commit. It never changes.                                     |
| `<version>`    | A release, such as `1.0.0`, built from the git tag `v1.0.0`. It never changes. |

`sample/docker-compose.yml` refers to a release so that the same file always runs the same image. To publish a release:

```sh
git tag v1.0.0
git push origin v1.0.0
```
