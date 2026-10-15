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

    The image is pulled from Docker Hub; the sample refers to a release (see [Image tags](#image-tags), which also covers the case where that release is not published yet). To build it from the `docker` directory instead, see [Building the image yourself](#building-the-image-yourself). On the first start each server creates its certificates, which can take a minute or two; follow it with `docker compose logs -f` and wait for `Initialization Sequence Completed`. If the container is stopped during this step, the next start begins the setup again.

    Each server keeps its data, including the private key of its certificate authority, in `sample/data/<name>`. Keep that directory private and back it up: it is ignored by git on purpose.

## Usage

Client management is handled by the `manage.sh` script inside each container. You can execute it using `docker compose exec` with the name of the service, from the `sample` directory.

### Generating a new client

To create a new client configuration, run the following command. Replace `my-client` with your desired client name.

```sh
docker compose exec vpn-personal manage.sh gen-client my-client
```

This generates `my-client.ovpn` in the server's data directory, which is `sample/data/personal/my-client.ovpn` on the host. The file contains the client's private key, so it is readable by root only (mode 600): copy it from the host with `sudo`, and hand it over through a secure channel. Names are 1 to 64 letters, digits, `.`, `_` or `-`, starting with a letter or a digit; `vpn_server` and `ca` are reserved.

The client certificate is valid for 825 days. To choose another validity, add the number of days; `0` means the maximum, 3650 days, and a larger number is refused because a certificate must not outlive the certificate authority:

```sh
docker compose exec vpn-personal manage.sh gen-client my-client 365
```

`gen-client` refuses a name that already has a certificate. To renew a client, revoke it and generate it again with the same name. If an issuance was interrupted (for example the container was stopped while signing), run the same command again: it discards the leftover request and key first.

### Regenerating a profile

When the server's address, port or protocol changes, the profiles already handed out keep the old values. Write them again from the existing certificates, without issuing new ones:

```sh
docker compose exec vpn-personal manage.sh export-client my-client
```

The client keeps its certificate and key; only the `remote`, port and protocol lines change. The same command recovers a profile that was deleted or that `gen-client` failed to write.

### Revoking a client

To revoke an existing client's access, run:

```sh
docker compose exec vpn-personal manage.sh revoke-client my-client
```

This revokes the client's certificate, updates the Certificate Revocation List (CRL) and deletes the client's `.ovpn` file. The OpenVPN server picks up the change by itself and refuses every new connection from this client. If the command is interrupted, run it again: it completes the revocation.

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
| `VPN_DNS`        | DNS servers pushed to the clients, as IPv4 addresses separated by commas (the tunnel carries no IPv6). | `1.1.1.1`                                       |
| `VPN_BLOCK_IPV6` | `1` blocks the clients' IPv6 traffic, `0` lets it through (also `true`/`false`, `yes`/`no`, `on`/`off`). See [IPv6](#ipv6). | `1` for a new server, `0` for one created by an older version |
| `OPENVPN`        | Path to the OpenVPN data directory inside the container, where configs and keys are stored.          | `/etc/openvpn`                                  |

Invalid values (a subnet that is not a `/24` network, a port outside 1-65535, a protocol other than `udp` or `tcp`, and so on) stop the container at start with a message that names the variable.

`server.conf` is written again from these variables every time the container starts, so a changed value takes effect with `docker compose up -d`. Manual edits to `server.conf` are overwritten. Profiles already handed out keep the address, port and protocol they were generated with: after changing one of those, run `export-client` for each client.

The container runs on the bridge network. `network_mode: host` is not supported: the NAT rule would end up in the host's tables and stay there after the container is gone.

### Custom server options

To add your own OpenVPN options, put them in `server.custom.conf` in the data directory (`sample/data/personal/server.custom.conf`). Its content is appended to `server.conf` at every start, so it survives the rewrite described above:

```text
push "route 192.168.77.0 255.255.255.0"
client-to-client
```

`VPN_IMAGE` is read by `docker-compose.yml` itself and selects the image to run.

### IPv6

The tunnel carries IPv4 only. So that a client with IPv6 connectivity does not keep reaching IPv6 sites outside the VPN, the server tells clients to route IPv6 into the tunnel and reject it there. Applications then fall back to IPv4. A client older than OpenVPN 2.5 does not know the instruction: it logs `Options error: Unrecognized option ... block-ipv6` and connects anyway (checked with 2.4.12; the `AES-256-GCM` cipher already requires 2.4). Its IPv6 traffic still enters the tunnel and is silently dropped by the server, so nothing leaks, but connections over IPv6 wait for a timeout before falling back.

The blocking is on for a server created by this version, and off for a volume created by an older one (recognised by its certificate authority already existing), so that an upgrade does not stop clients from connecting. The choice is stored in `.block-ipv6-default` in the data directory at the first start. The start log says which mode is active and why. Set `VPN_BLOCK_IPV6=1` to turn it on for an upgraded server; setting `0` or `1` always wins over the default.

A client whose operating system has IPv6 disabled cannot apply the blocking and fails to connect with `Linux can't add IPv6 to interface tun0`. Either add this line to that client's `.ovpn` file:

```text
pull-filter ignore "ifconfig-ipv6"
```

or set `VPN_BLOCK_IPV6=0` on the server, which turns the protection off for all its clients.

### Certificates

The certificate authority and the server certificate are valid for 10 years, and every start logs the server certificate's expiry date. A server certificate that is within 30 days of expiry, or that was issued with the 825-day validity of older versions, is renewed when the container starts; client profiles keep working after that, because the certificate authority does not change. When the certificate authority itself expires, the data directory has to be created again together with all client profiles.

## Building the image yourself

To run an image built from your checkout instead of a published release, add the build override:

```sh
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

The image is tagged `docker-vpn:local`, so it is never mistaken for a release.

## Upgrading

An existing data directory keeps working with a newer image, and the certificate authority and the client profiles are not touched. At the first start:

- the server certificate is replaced if it is one of the 825-day certificates of older versions;
- the `.ovpn` profiles that other users could read (mode 644, as older versions wrote them) are set to 600, because they contain the client's private key; on a data directory mounted from the host, copying them now needs `sudo`;
- `server.conf` is rewritten; the previous file is kept as `server.conf.bak.<date>`, and its custom lines belong in `server.custom.conf`;
- revoked clients start being refused (older versions never read the CRL);
- the IPv6 blocking stays off, as described in [IPv6](#ipv6).

A setup that an older version left half-built (a `pki` directory with missing files) stops the container with `PKI incompleta`. Remove the `pki` directory to create it again; profiles issued from it are not valid anymore.

## Image tags

The image is published to Docker Hub as `dockerdima/docker-vpn` whenever the `docker` directory changes on `main`:

| Tag            | Meaning                                                                        |
| :------------- | :----------------------------------------------------------------------------- |
| `latest`       | The most recent build of `main`. It changes over time.                         |
| `sha-<commit>` | The build of one commit of `main`. Re-running the workflow for the same commit rebuilds it. |
| `<version>`    | A release, such as `1.0.0`, built from the git tag `v1.0.0`. It is published once: the workflow refuses to overwrite an existing version. |

`sample/docker-compose.yml` refers to a release so that the same file always runs the same image. The project follows git flow (`main` holds the releases, `develop` the work in progress), so a release is prepared on a `release/<version>` branch:

```sh
git flow release start 1.0.0
# On this branch only the release number (the image in sample/docker-compose.yml and
# the VPN_IMAGE example above) and fixes change; no new features.
git flow release finish -m "Release 1.0.0" 1.0.0
git push origin main develop v1.0.0
```

Give git flow the bare number (`1.0.0`): its version tag prefix is `v`, so `release finish` merges the branch into `main` and `develop` and creates the tag `v1.0.0` itself. Pushing `main` publishes `latest` and `sha-<commit>`; pushing the tag publishes `1.0.0`.

Until `v1.0.0` has been pushed there is no `1.0.0` image, and `docker compose up -d` fails with `manifest ... not found`. In that case set `VPN_IMAGE=dockerdima/docker-vpn:latest` in `sample/.env`, or build the image yourself.

Before anything is published, the workflow checks the scripts with `shellcheck` and runs two of the end-to-end tests (`t_manage`, `t_revoke`); if they fail, no image is pushed.
