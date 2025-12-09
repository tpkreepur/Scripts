# INSTALL SCRIPTS

## LINUX REQUIREMENTS

- curl
- unzip
- wget
- git
- prometheus exporters
  - node_exporter

## MONITORING

### PROMETHEUS

Latest version: <https://github.com/prometheus/node_exporter/releases/latest>

## Oh My Posh - Terminal customization

Run the install using the official install script:

`curl -s https://ohmyposh.dev/install.sh | sudo bash -s -- -d /usr/bin -t /usr/share/oh-my-posh/themes`

An alias to update can be set with:

`alias update-omp='curl -s https://ohmyposh.dev/install.sh | bash -s -- -d $HOME/.local/bin -t $HOME/.local/share/oh-my-posh/themes'`

Or add the alias to the _.bash_aliases_ file.
