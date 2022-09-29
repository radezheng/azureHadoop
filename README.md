# 使用Terraform/Ansible在Azure上部署Hadoop

为了Infrastructure As Code, 命令式的可以使用Azure CLI/Power Shell, 声明式的在Azure可以使用ARM, Bicep。声明式的好处是只需要定义需要什么资源，在什么地方，处于什么状态，后台自动按要求执行达到所需目标，所以要做CI/CD, 一般使用声明式的，但ARM,Bicep都需要稍微学习，而且只能用在Azure上。如果想为了跨云，可以使用Terraform这种声明式的来创建资源，学一种语言可以用在多个云，甚至本地。资源创建之后的配置，产品安装可以使用Ansible来完成，当然也可以使用自定义镜像的方式加快配置速度。 <br/>

下面我们以Hadoop为例，将其部署在Azure的VM或VMSS上，并配置通过ADLS gen2实现存算分离。当然这只是个简单的示例，仅供参考。

## 环境安装

Terraform 参考 https://learn.hashicorp.com/tutorials/terraform/install-cli <br/>
Ansible 参考 https://cn-ansibledoc.readthedocs.io/zh_CN/latest/installation_guide/intro_installation.html

<br/>
另外需要配置 Azure和Terraform的验证权限， 参考 https://learn.microsoft.com/zh-cn/azure/developer/terraform/authenticate-to-azure?tabs=bash  <br/>
<br/>

## Terraform 基本用法
Terraform 使用.tf 文件定义所声明的资源，放几个文没关系，按目录执行，可以定义输入，输出和变量，更详细的用法参考官方教程，与Azure各服务的结合参考 https://learn.microsoft.com/zh-cn/azure/developer/terraform/overview
<br/>
这里的示例Terraform 基本用下面几个命令就可以

```bash
# 基于当前目录，初始化
terraform init

# 按当前定义文件编译执行计划 tfplan
terraform plan  -out test.tfplan

# 基于计划执行资源创建
terraform apply  test.tfplan
```

## 创建一台虚机
参考 [/vm](./vm/) <br/>
创建VNet,subnet, nsg, 并引用Keyvault生成密钥作为虚机登录的证书，主要在:
```ARM
data "azurerm_key_vault" "kvexample" {
  name                = "kvexample888"
  resource_group_name = "examplerg"
}

data "azurerm_key_vault_secret" "sshkey" {
  name         = "pubkey-test"
  key_vault_id = data.azurerm_key_vault.kvexample.id
}
```

只需要在该目录下，执行Terraform基本用法的三个命令就可以，即 terraform init/plan/apply

Keyvault的创建参考 [/keyvault](./keyvault/), 主要注意网络访问限制。如果是测试阶段，也可以将默认设为Allow, 或在Portal里的Keyvault的网络里打开限制。
```json
    network_acls {
        default_action             = "Deny"
        bypass                     = "AzureServices"
        ip_rules                   = ["167.220.255.12"]
    }
```

密钥下载可以使用Azure CLI
```bash
az keyvault secret download --vault-name kvexample888 -n prikey-test  -f cert1.pem

chmod 400 cert1.pem
```

然后就可以 ssh -i cert1.pem azureuser@[ip]

## 并行创建多台虚机

大数据平台的运行往往需要多台机器搭成集群，比如Hadoop需要多台Master和Worker, 就需要创建多台一样的机器。Terraform提供了非常方便的途径来实现，只需要在定义的资源里加上 **count** 的参数指定数量就可以，当然实际用来创建虚机时，需要同时创建相同数量的其他相关资源，如网卡，IP, 或者公用的资源，如VNet, NSG等。为了方便，可以分开不同的资源为不同的模块(Module)，在需要创建的时候引用相关的模块就好。所以这里将网络和虚机分成了两个模块，创建多台节点的集群，先引用VNet模块创建一个VNet, 然后再传进虚机模块基于这个VNet创建多台机器。具体可以参考
 [vmModTest/main.tf](./vmModTest/main.tf) 引用了 : <br/>
 - [modules/vnet/main.tf](./modules/vnet/main.tf) 创建VNet
 - [modules/vmVnet/main.tf](./modules/vmVnet/main.tf) 创建虚机
 - 或者 [modules/vmssVnet/main.tf](./modules/vmssVnet/main.tf) 创建虚机规模集(VMSS)
```ARM

#创建资源组
resource "azurerm_resource_group" "hdrg" {
  name     = "testrg"
  location = "eastasia"
}

#引用vnet模块创建VNet和subnet
module "hd-vnet" {
  source     = "../modules/vnet"
  vnetName   = "hdvnet"
  region     = azurerm_resource_group.hdrg.location
  rgName     = azurerm_resource_group.hdrg.name
  subnetName = "hdsubnet"

  depends_on = [
    azurerm_resource_group.hdrg,
  ]
}


#创建多台虚机
module "testvm" {
  source       = "../modules/vmVnet"
  vmNamePrefix = "testvm"
  #指定虚机的数目
  vmcount      = 2
  vnetName     = module.hd-vnet.vnetName
  vnetRG       = azurerm_resource_group.hdrg.name
  subnetName   = module.hd-vnet.subnetName
  rgLocation   = azurerm_resource_group.hdrg.location
  rgName       = azurerm_resource_group.hdrg.name
  #是否创建公网IP
  public_ip    = true
  #是否为Spot实例
  spot         = true
  #可以指定创建虚机的镜像，默认为CentOS 7.9, 如下面可以改为Ubuntu 20.04
  # image_offer = "0001-com-ubuntu-server-focal"
  # image_publisher = "Canonical"
  # image_sku = "20_04-lts"
  kvName       = "kvexample888"
  kvRG         = "exampleRG"
  kvKeyName = "pubkey-test"
  vmSize    = "Standard_D2S_v3"

  depends_on = [
    module.hd-vnet,
    azurerm_resource_group.hdrg,
  ]
}
```

## 创建并配置Hadoop集群
有了上面的基础，我们就可以按需要来创建Hadoop集群，但有两点需要注意：
- 安全起见，Hadoop集群不建议配置公网IP, 这就需要使用跳板机(Jumpbox)，然后hadoop集群节点都只有内网IP ( public_ip = false ), 
- 为了配置方便，需要各节点间ssh互信。这就需要创建完VM后，从Keyvault 下载密钥到本机的 .ssh/id_rsa 。但这些配置需要ssh连接上各节点，所以terraform只能在跳板机执行。
```ARM
  provisioner "file" {
    content      = data.azurerm_key_vault_secret.sshkey.value
    destination = "/home/${var.userName}/.ssh/id_rsa"
    
        connection {
      type        = "ssh"
      user        = var.userName
      private_key = file("~/cert1.pem")
      host        = "${var.public_ip?self.public_ip_address:"localhost"}"
    }
  }
```
- 创建完节点，hadoop的安装配置建议使用Ansible, 也需要在跳板机执行。
<br/>
<br/>
所以我们先要创建一个跳板机，作为Terraform/Ansible的执行，参考 [ansibleHost/main.tf](./ansibleHost/main.tf)
<br/>
然后再在ansibleHost这台机器上安装Terraform/Ansible/Azure CLI,参考“环境准备”环节， 再把脚本clone到ansibleHost上，然后执行创建hadoop集群，参考 [hdvm/main.tf](./hdvm/main.tf)