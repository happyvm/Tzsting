@{
    ExcludeRules = @(
        # run_guest_command's PowerShell Direct branch converts a plaintext
        # password (received as plaintext from Ansible/ansible-vault - the
        # automation input path already handles secrecy at that layer) into
        # a PSCredential for one-time use with Invoke-Command -Credential.
        # There's no encrypted SecureString to start from here, so this is
        # the correct, unavoidable way to build the credential, not the
        # hardcoded-plaintext-secret anti-pattern this rule targets.
        'PSAvoidUsingConvertToSecureStringWithPlainText'
    )
}
