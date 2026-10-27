# Production: one stamp per data region, one global edge in front.
# Applied only by the pipeline (pipelines/infra.yml), never from a laptop.

terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.20"
    }
  }

  backend "azurerm" {
    use_azuread_auth = true
    container_name   = "tfstate"
    key              = "prod.tfstate"
  }
}

provider "azurerm" {
  features {}
  storage_use_azuread = true
}

locals {
  tags = {
    owner       = "platform-team"
    cost-center = var.cost_center
  }
}

module "stamp_eu" {
  source        = "../../modules/region-stamp"
  data_region   = "eu"
  location      = "westeurope"
  environment   = "prod"
  address_space = "10.10.0.0/16"
  tags          = local.tags
}

module "stamp_us" {
  source        = "../../modules/region-stamp"
  data_region   = "us"
  location      = "eastus2"
  environment   = "prod"
  address_space = "10.20.0.0/16"
  tags          = local.tags
}

resource "azurerm_resource_group" "global" {
  name     = "rg-rcp-global-prod"
  location = "westeurope"
  tags     = merge(local.tags, { data-region = "global" })
}

module "edge" {
  source              = "../../modules/global-edge"
  environment         = "prod"
  resource_group_name = azurerm_resource_group.global.name
  regions             = var.edge_regions
  tags                = merge(local.tags, { data-region = "global" })
}
