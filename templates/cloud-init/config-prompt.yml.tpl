write_files:
    - path: /etc/profile.d/illinois-prompt.sh
      owner: root:root
      permissions: '0644'
      content: |
          [ "$PS1" ] && PS1="[\u@${prompt_name} \W]\\$ "

merge_type: 'list(append)+dict(recurse_array)+str()'
