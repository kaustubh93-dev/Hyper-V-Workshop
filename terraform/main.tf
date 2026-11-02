locals {
  is_bastion_standard = var.bastion_sku == "Standard"
  host_names          = [for i in range(var.host_count) : "${var.name_prefix}-${i + 1}"]

  host_setup_source = var.use_local_scripts ? tomap({
    script = file("${path.module}/../scripts/setup-host.ps1")
    }) : tomap({
    scriptUri = var.host_setup_script_uri
  })
  mslab_setup_source = var.use_local_scripts ? tomap({
    script = file("${path.module}/../scripts/mslab-host.ps1")
    }) : tomap({
    scriptUri = var.mslab_setup_script_uri
  })
}

resource "azurerm_resource_group" "lab" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# Defender JIT may strip these rules; scripts/start-lab.ps1 re-adds them
resource "azurerm_network_security_group" "hosts" {
  name                = "${var.name_prefix}-nsg"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags

  security_rule {
    name                       = "Allow-RDP-From-Bastion-Developer"
    priority                   = 300
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "168.63.129.16"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "3389"
  }

  security_rule {
    name                       = "Allow-RDP-From-Bastion-Subnet"
    priority                   = 310
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = var.bastion_subnet_prefix
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "3389"
  }
}

resource "azurerm_virtual_network" "lab" {
  name                = var.vnet_name
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = [var.vnet_address_prefix]
  tags                = var.tags
}

resource "azurerm_subnet" "hosts" {
  name                            = var.subnet_name
  resource_group_name             = azurerm_resource_group.lab.name
  virtual_network_name            = azurerm_virtual_network.lab.name
  address_prefixes                = [var.subnet_prefix]
  default_outbound_access_enabled = true
}

resource "azurerm_subnet_network_security_group_association" "hosts" {
  subnet_id                 = azurerm_subnet.hosts.id
  network_security_group_id = azurerm_network_security_group.hosts.id
}

resource "azurerm_subnet" "bastion" {
  count                = local.is_bastion_standard ? 1 : 0
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.bastion_subnet_prefix]
}

resource "azurerm_public_ip" "bastion" {
  count               = local.is_bastion_standard ? 1 : 0
  name                = "${var.vnet_name}-bastion-pip"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_bastion_host" "lab" {
  name                   = "${var.vnet_name}-bastion"
  location               = azurerm_resource_group.lab.location
  resource_group_name    = azurerm_resource_group.lab.name
  sku                    = var.bastion_sku
  shareable_link_enabled = local.is_bastion_standard
  virtual_network_id     = local.is_bastion_standard ? null : azurerm_virtual_network.lab.id
  tags                   = var.tags

  dynamic "ip_configuration" {
    for_each = local.is_bastion_standard ? [1] : []
    content {
      name                 = "ipconfig1"
      subnet_id            = azurerm_subnet.bastion[0].id
      public_ip_address_id = azurerm_public_ip.bastion[0].id
    }
  }
}

resource "azurerm_network_interface" "host" {
  count                          = var.host_count
  name                           = "${local.host_names[count.index]}-nic"
  location                       = azurerm_resource_group.lab.location
  resource_group_name            = azurerm_resource_group.lab.name
  accelerated_networking_enabled = true
  tags                           = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    primary                       = true
    subnet_id                     = azurerm_subnet.hosts.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_windows_virtual_machine" "host" {
  count                     = var.host_count
  name                      = local.host_names[count.index]
  computer_name             = local.host_names[count.index]
  location                  = azurerm_resource_group.lab.location
  resource_group_name       = azurerm_resource_group.lab.name
  zone                      = var.zone
  size                      = var.vm_size
  admin_username            = var.admin_username
  admin_password            = var.admin_password
  network_interface_ids     = [azurerm_network_interface.host[count.index].id]
  provision_vm_agent        = true
  automatic_updates_enabled = false
  patch_mode                = "Manual"
  patch_assessment_mode     = "ImageDefault"
  secure_boot_enabled       = true
  vtpm_enabled              = true
  tags                      = var.tags

  os_disk {
    name                 = "${local.host_names[count.index]}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2025-datacenter-g2"
    version   = "latest"
  }

  boot_diagnostics {}

  # start-lab.ps1 resizes hosts on capacity errors; don't fight it on the next apply
  lifecycle {
    ignore_changes = [size]
  }
}

resource "azurerm_managed_disk" "data" {
  count                = var.host_count
  name                 = "${local.host_names[count.index]}-datadisk0"
  location             = azurerm_resource_group.lab.location
  resource_group_name  = azurerm_resource_group.lab.name
  zone                 = var.zone
  storage_account_type = var.data_disk_sku
  create_option        = "Empty"
  disk_size_gb         = var.data_disk_size_gb
  tags                 = var.tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  count              = var.host_count
  managed_disk_id    = azurerm_managed_disk.data[count.index].id
  virtual_machine_id = azurerm_windows_virtual_machine.host[count.index].id
  lun                = 0
  caching            = "ReadOnly"
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "host" {
  count                 = var.host_count
  virtual_machine_id    = azurerm_windows_virtual_machine.host[count.index].id
  location              = azurerm_resource_group.lab.location
  enabled               = true
  daily_recurrence_time = replace(var.auto_shutdown_time, ":", "")
  timezone              = var.auto_shutdown_time_zone
  tags                  = var.tags

  notification_settings {
    enabled         = var.auto_shutdown_notification_email != ""
    email           = var.auto_shutdown_notification_email != "" ? var.auto_shutdown_notification_email : null
    time_in_minutes = 30
  }
}

resource "azapi_resource" "setup_hyperv" {
  count     = var.host_count
  type      = "Microsoft.Compute/virtualMachines/runCommands@2024-07-01"
  name      = "setup-hyperv"
  parent_id = azurerm_windows_virtual_machine.host[count.index].id
  location  = azurerm_resource_group.lab.location
  tags      = var.tags

  body = {
    properties = {
      source                          = local.host_setup_source
      parameters                      = [{ name = "NatPrefix", value = var.nested_nat_prefix }]
      asyncExecution                  = false
      timeoutInSeconds                = 3600
      treatFailureAsDeploymentFailure = true
    }
  }

  timeouts {
    create = "75m"
  }

  # setup-host.ps1 formats the data disk as V:
  depends_on = [azurerm_virtual_machine_data_disk_attachment.data]
}

resource "azapi_resource" "setup_mslab" {
  count     = var.deploy_mslab ? var.host_count : 0
  type      = "Microsoft.Compute/virtualMachines/runCommands@2024-07-01"
  name      = "setup-mslab"
  parent_id = azurerm_windows_virtual_machine.host[count.index].id
  location  = azurerm_resource_group.lab.location
  tags      = var.tags

  body = {
    properties = {
      source = local.mslab_setup_source
      parameters = [
        { name = "NodeCount", value = tostring(var.mslab_node_count) },
        { name = "NodeMemoryGB", value = tostring(var.mslab_node_memory_gb) },
      ]
      asyncExecution                  = true
      timeoutInSeconds                = 600
      treatFailureAsDeploymentFailure = false
    }
  }

  depends_on = [azapi_resource.setup_hyperv]
}
