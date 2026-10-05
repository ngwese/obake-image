sudo apt install usb-modeswitch
sudo cp jack@.service /usr/lib/systemd/user/
sudo vi /etc/security/limits.conf (for rtprio and ulimited memlock for @audio)
sudo usermod -a -G uucp greg
sudo usermod -a -G dialout greg
sudo usermod -a -G input greg (questionable due to security)
