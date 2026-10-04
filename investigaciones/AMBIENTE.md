## Instalar terraform en servidor BASTION - EC2 Amazon Linux

```bash
sudo yum install -y yum-utils shadow-utils
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo yum install terraform
```

## Instalar AWS-CLI en servidor BASTION - EC2 Amazon Linux

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
sudo ./aws/install
rm -rf awscliv2.zip aws/
aws --version
```


## Instalar KUBECTL CLI en servidor BASTION - EC2 Amazon Linux

```bash
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl
kubectl version --client
```

## Instalar Azure CLI en servidor BASTION - EC2 - Amazon Linux

```bash
sudo dnf update -y
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
cat <<EOF | sudo tee /etc/yum.repos.d/azure-cli.repo
[azure-cli]
name=Azure CLI
baseurl=https://packages.microsoft.com/yumrepos/azure-cli
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
sudo dnf install -y azure-cli
az --version
```

