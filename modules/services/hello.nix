# Example user service: logs a hello message and basic system info on boot.
#
# To enable, add to your configuration.nix:
#
#   imports = [
#     ./hardware/pico-mini-b.nix
#     ./modules/services/hello.nix
#   ];
#
# The service runs once after boot and writes to /var/log/hello.log.
# Check the output with:  cat /var/log/hello.log

{ ... }:

{
  services.user.hello = {
    enable = true;
    action = "once";           # run once at boot, do not restart
    script = ''
      LOG=/var/log/hello.log

      echo "==============================" >> $LOG
      echo "Hello from Luckfox!"           >> $LOG
      echo "  date:    $(date)"            >> $LOG
      echo "  uptime:  $(cat /proc/uptime)" >> $LOG
      echo "  uname:   $(uname -a)"        >> $LOG
      echo "  memory:"                     >> $LOG
      cat /proc/meminfo | grep -E '^(MemTotal|MemFree):' >> $LOG
      echo "==============================" >> $LOG
    '';
  };
}
