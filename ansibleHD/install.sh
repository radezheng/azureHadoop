az group create --name testRG --location eastasia

terraform init

terraform plan  -out test.tfplan

terraform apply  test.tfplan
