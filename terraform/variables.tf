variable "subscription_id" {
  type        = string
  description = "Target subscription. Null uses ARM_SUBSCRIPTION_ID or the Azure CLI default."
  default     = null
}

variable "resource_group_name" {
  type    = string
  default = "HYPER-V-WORKSHOP-RG"
}

variable "location" {
  type    = string
  default = "eastus2"
}

variable "host_count" {
  type    = number
  default = 2

  validation {
    condition     = var.host_count >= 1 && var.host_count <= 6
    error_message = "host_count must be 1-6."
  }
}

variable "name_prefix" {
  type        = string
  description = "Hosts are named <prefix>-1..N; kept short so the computer name stays within 15 chars."
  default     = "HYD-HOST"

  validation {
    condition     = length(var.name_prefix) <= 13
    error_message = "name_prefix must be 13 characters or fewer."
  }
}

variable "vm_size" {
  type        = string
  description = "Diskless sizes that support nested virtualization."
  default     = "Standard_D8as_v5"

  validation {
    condition = contains([
      "Standard_D8s_v5", "Standard_D8s_v4", "Standard_D16s_v5",
      "Standard_E8s_v5", "Standard_E8s_v4", "Standard_E4s_v5", "Standard_E4s_v4",
      "Standard_D8as_v5", "Standard_E8as_v5", "Standard_E4as_v5", "Standard_D16as_v5",
    ], var.vm_size)
    error_message = "vm_size must be a diskless nested-virtualization size from the allowed list."
  }
}

variable "admin_username" {
  type    = string
  default = "labadmin"
}

variable "admin_password" {
  type      = string
  sensitive = true

  validation {
    condition     = length(var.admin_password) >= 12
    error_message = "admin_password must be at least 12 characters."
  }
}

variable "zone" {
  type        = string
  description = "In eastus2 this subscription is restricted (NotAvailableForSubscription) from zones 1 and 3 for the lab sizes."
  default     = "2"

  validation {
    condition     = contains(["1", "2", "3"], var.zone)
    error_message = "zone must be 1, 2 or 3."
  }
}

variable "os_disk_type" {
  type    = string
  default = "Premium_LRS"

  validation {
    condition     = contains(["Premium_LRS", "StandardSSD_LRS"], var.os_disk_type)
    error_message = "os_disk_type must be Premium_LRS or StandardSSD_LRS."
  }
}

variable "data_disk_size_gb" {
  type    = number
  default = 1024

  validation {
    condition     = var.data_disk_size_gb >= 128 && var.data_disk_size_gb <= 4095
    error_message = "data_disk_size_gb must be 128-4095."
  }
}

variable "data_disk_sku" {
  type    = string
  default = "Premium_LRS"

  validation {
    condition     = contains(["Premium_LRS", "StandardSSD_LRS"], var.data_disk_sku)
    error_message = "data_disk_sku must be Premium_LRS or StandardSSD_LRS."
  }
}

variable "vnet_name" {
  type    = string
  default = "vnet-hyperv-training"
}

variable "vnet_address_prefix" {
  type    = string
  default = "172.16.0.0/16"
}

variable "subnet_name" {
  type    = string
  default = "snet-hosts"
}

variable "subnet_prefix" {
  type    = string
  default = "172.16.0.0/24"
}

variable "bastion_sku" {
  type        = string
  description = "Developer is the no-public-IP default. Standard enables shareable links and requires subscription public-IP prerequisites."
  default     = "Developer"

  validation {
    condition     = contains(["Developer", "Standard"], var.bastion_sku)
    error_message = "bastion_sku must be Developer or Standard."
  }
}

variable "bastion_subnet_prefix" {
  type        = string
  description = "AzureBastionSubnet (min /26), used only with the Standard SKU."
  default     = "172.16.1.0/26"
}

variable "auto_shutdown_time" {
  type    = string
  default = "21:00"

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.auto_shutdown_time))
    error_message = "auto_shutdown_time must be HH:MM (24h)."
  }
}

variable "auto_shutdown_time_zone" {
  type    = string
  default = "India Standard Time"
}

variable "auto_shutdown_notification_email" {
  type    = string
  default = ""
}

variable "use_local_scripts" {
  type        = bool
  description = "Send ../scripts/*.ps1 inline instead of downloading them from the script URIs."
  default     = false
}

variable "host_setup_script_uri" {
  type    = string
  default = "https://raw.githubusercontent.com/kaustubh93-dev/Hyper-V-Workshop/main/scripts/setup-host.ps1"
}

variable "mslab_setup_script_uri" {
  type    = string
  default = "https://raw.githubusercontent.com/kaustubh93-dev/Hyper-V-Workshop/main/scripts/mslab-host.ps1"
}

variable "nested_nat_prefix" {
  type    = string
  default = "192.168.0.0/24"
}

variable "deploy_mslab" {
  type        = bool
  description = "Build MSLab (DC + Server 2025 nodes) on each host after Hyper-V setup; runs ~1.5 h in the background."
  default     = true
}

variable "mslab_node_count" {
  type    = number
  default = 3

  validation {
    condition     = var.mslab_node_count >= 0 && var.mslab_node_count <= 6
    error_message = "mslab_node_count must be 0-6."
  }
}

variable "mslab_node_memory_gb" {
  type    = number
  default = 5

  validation {
    condition     = var.mslab_node_memory_gb >= 2 && var.mslab_node_memory_gb <= 16
    error_message = "mslab_node_memory_gb must be 2-16."
  }
}

variable "tags" {
  type = map(string)
  default = {
    purpose = "hyperv-training"
  }
}
