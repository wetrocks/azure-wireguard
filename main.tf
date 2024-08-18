terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "3.110.0"
    }
  }
}

provider "azurerm" {
  features {}
}

locals {
  filename = "${path.module}/id_rsa_vpn.pub"
  file_pubkey  = fileexists(local.filename) ? chomp(file(local.filename)) : null
  server_ssh_name = "${var.wgserver_name}-ssh"
}

data "azurerm_ssh_public_key" "existing_sshkey" {
  count = fileexists(local.filename) ? 0 : 1
  
  name                = local.server_ssh_name
  resource_group_name = azurerm_resource_group.rg.name
}

locals {
  existing_sshkey = one(data.azurerm_ssh_public_key.existing_sshkey[*].public_key)
}

resource "azurerm_resource_group" "rg" {
  name     = var.rg_name
  location = var.rg_location
}

resource "azurerm_ssh_public_key" "server_ssh" {
  name                = local.server_ssh_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  public_key          = coalesce(local.existing_sshkey, local.file_pubkey)
}


resource "azurerm_virtual_network" "vnet" {
  name                = var.vnet_name
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "wg_subnet" {
  name                 = var.subnet_name
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.42.0/26"]
}

resource "azurerm_public_ip" "wg_public_ip" {
  name                = var.public_ip_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  domain_name_label   = var.public_ip_dnslabel
}

resource "azurerm_network_security_group" "wg_nsg" {
  name                = var.nsg_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_network_security_rule"  "security_rule_wg" {
    name                       = "AllowWireGuardInbound"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = "51820"
    source_address_prefix      = "*"
    destination_address_prefix = azurerm_subnet.wg_subnet.address_prefixes[0]
    resource_group_name = azurerm_resource_group.rg.name
    network_security_group_name = azurerm_network_security_group.wg_nsg.name
  }

  # resource "azurerm_network_security_rule"  "security_rule_ssh_bastiondev" {
  #   name                       = "AllowBastionDevSSHInbound"
  #   priority                   = 1000
  #   direction                  = "Inbound"
  #   access                     = "Allow"
  #   protocol                   = "Tcp"
  #   source_port_range          = "*"
  #   destination_port_range     = "22"
  #   source_address_prefix      = "168.63.129.16"
  #   destination_address_prefix = azurerm_subnet.wg_subnet.address_prefixes[0]
  #   resource_group_name = azurerm_resource_group.rg.name
  #   network_security_group_name = azurerm_network_security_group.wg_nsg.name
  # }

  resource "azurerm_network_security_rule"  "security_rule_ssh_public" {
    name                       = "AllowAnySSHInbound"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = azurerm_subnet.wg_subnet.address_prefixes[0]
    resource_group_name = azurerm_resource_group.rg.name
    network_security_group_name = azurerm_network_security_group.wg_nsg.name
  }

resource "azurerm_network_interface" "wg_nic" {
  name                = var.wgserver_nic
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "tf_nic_configuration"
    subnet_id                     = azurerm_subnet.wg_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.wg_public_ip.id
  }
}

resource "azurerm_network_interface_security_group_association" "wg_nic_nsg" {
  network_interface_id      = azurerm_network_interface.wg_nic.id
  network_security_group_id = azurerm_network_security_group.wg_nsg.id
}

resource "azurerm_linux_virtual_machine" "wg_server" {
  name                = var.wgserver_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = "Standard_B2s"
  admin_username      = "wgadminuser"
  identity {
    type = "SystemAssigned"
  }

  network_interface_ids = [
    azurerm_network_interface.wg_nic.id
  ]

  admin_ssh_key {
    username   = "wgadminuser"
    public_key = azurerm_ssh_public_key.server_ssh.public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  custom_data = base64encode(templatefile(
                              "cloud-init.yml.tftpl",
                              {
                                public_ip = azurerm_public_ip.wg_public_ip.ip_address
                              })
                            )
}

resource "azurerm_virtual_machine_extension" "aad_login" {
  name                 = "AADLogin"
  virtual_machine_id   = azurerm_linux_virtual_machine.wg_server.id
  publisher            = "Microsoft.Azure.ActiveDirectory"
  type                 = "AADSSHLoginForLinux" 
  type_handler_version = "1.0"
}



# resource "azurerm_key_vault" "keyvault" {
#   name                        = "wg_keyvault"
#   location                    = azurerm_resource_group.example.location
#   resource_group_name         = azurerm_resource_group.example.name
#   enabled_for_disk_encryption = true
#   tenant_id                   = data.azurerm_client_config.current.tenant_id
#   soft_delete_retention_days  = 7
#   purge_protection_enabled    = false

#   sku_name = "standard"

#   access_policy {
#     tenant_id = data.azurerm_client_config.current.tenant_id
#     object_id = data.azurerm_client_config.current.object_id

#     key_permissions = [
#       "Get",
#     ]

#     secret_permissions = [
#       "Get",
#     ]

#     storage_permissions = [
#       "Get",
#     ]
#   }
# }

