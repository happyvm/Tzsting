@{
    ExcludeRules = @(
        # -ComputerName '{{ scvmm_server }}' (preflight_platform,
        # delete_vm_lock, decommission_stop_scvmm, delete_vm_scvmm) is a
        # Jinja placeholder resolved at Ansible runtime from
        # group_vars/inventory, not a real hardcoded hostname in the
        # source - our extraction script substitutes {{ }} with a plain
        # number for static analysis, which is exactly what makes this
        # rule misfire (it can't tell a templated value from a literal).
        'PSAvoidUsingComputerNameHardcoded'
    )
}
