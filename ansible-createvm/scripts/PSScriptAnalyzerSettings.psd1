@{
    ExcludeRules = @(
        # -ComputerName '{{ scvmm_server }}' (preflight_create_constraints,
        # create_vm_lock, create_vm_scvmm) is a Jinja placeholder
        # resolved at Ansible runtime from group_vars/inventory, not a
        # real hardcoded hostname in the source - our extraction script
        # substitutes {{ }} with a plain number for static analysis,
        # which is exactly what makes this rule misfire (it can't tell a
        # templated value from a literal).
        'PSAvoidUsingComputerNameHardcoded'
        # create_vm_scvmm converts a plaintext domain/local admin
        # password (received as plaintext from Ansible/ansible-vault -
        # the automation input path already handles secrecy at that
        # layer) into a PSCredential for one-time use with
        # New-SCVirtualMachine. There's no encrypted SecureString to
        # start from here, so this is the correct, unavoidable way to
        # build the credential, not the hardcoded-plaintext-secret
        # anti-pattern this rule targets.
        'PSAvoidUsingConvertToSecureStringWithPlainText'
    )
}
