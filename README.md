## Setup
```shell
  cp .env.example .env
```

`TF_VAR_ubuntu_ami_id=ami-0cfde0ea8edd312d4`
This is the Ubuntu 24.04 LTS in us-east-2 AMI ID (at time of writing). Change this 
if outdated or in another region.

---

Trying not to rely on too many external dependencies, there's some bash helper 
aliases/functions in `helpers.sh`. If on Windows/WSL, make sure `.env` file 
separator is set to `LF`; `CR` or `CRLF` will pick up `\r` as part of the values 
with this basic alias. 

In your current session run:
```shell
  source ./helpers.sh
```
Then use `t` instead of `tofu`, ie `t plan`, `t apply`, etc.

Alternatively you could set up https://direnv.net/ to read the `.env` file.

## Security Concerns
 
- Currently, all keys (private and public) are all plaintext in the state file, which is a local file.
- The user_data.sh cat of wg0.conf content does not seem to appear in the logs,
