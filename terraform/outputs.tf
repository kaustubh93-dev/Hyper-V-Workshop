output "resource_group_name" {
  value = azurerm_resource_group.lab.name
}

output "hosts" {
  value = [for i, vm in azurerm_windows_virtual_machine.host : {
    name       = vm.name
    private_ip = azurerm_network_interface.host[i].private_ip_address
  }]
}

output "bastion_name" {
  value = azurerm_bastion_host.lab.name
}

output "next_steps" {
  value = join("", [
    var.deploy_mslab ? "MSLab builds in the background (~1.5 h); progress in C:\\MSLabSetup\\status.txt on each host. " : "",
    local.is_bastion_standard
    ? "Student browser access: portal > ${azurerm_bastion_host.lab.name} > Shareable links > Add."
    : "Connect: portal > VM > Connect > Bastion.",
  ])
}
