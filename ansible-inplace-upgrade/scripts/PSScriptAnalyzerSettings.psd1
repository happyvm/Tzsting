@{
    # Nothing is suppressed for this project, and nothing needs to be: all
    # six extracted scripts pass Error and Warning analysis unsuppressed.
    #
    # The two rules ansible-resizedisk excludes do not apply here. This
    # project never builds a PSCredential out of a plaintext password (the
    # guest is reached over WinRM/SSH by Ansible itself, never through
    # PowerShell Direct), and no embedded script passes a Jinja-templated
    # -ComputerName that the extraction step's numeric placeholder would
    # make look like a hardcoded hostname.
    #
    # Add an entry only with a comment naming the script it applies to and
    # why the rule genuinely misfires there - not by copying another
    # project's list.
    ExcludeRules = @()
}
