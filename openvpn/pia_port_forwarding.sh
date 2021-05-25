#!/bin/bash
echo "Starting script"
export PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin:/root/bin

# Vers: 0.1 beta
# Date: 9/14/2020

###### PIA Variables ######
curl_max_time=15
curl_retry=5
curl_retry_delay=15
exec 6< /config/openvpn/credentials.conf

read user <&6
read pass <&6

CONFFILE=/config/qBittorrent/config/qBittorrent.conf

###### Nextgen PIA port forwarding      ##################

get_auth_token () {
    tok=$(curl --insecure --silent --show-error --request POST --max-time $curl_max_time \
        --header "Content-Type: application/json" \
        --data "{\"username\":\"$user\",\"password\":\"$pass\"}" \
        "https://www.privateinternetaccess.com/api/client/v2/token" | jq -r '.token')
    [ $? -ne 0 ] && echo "Failed to acquire new auth token" && exit 1
    echo "$tok"
}

echo "getting token"
get_auth_token #> /dev/null 2>&1
echo "done getting token"

bind_port () {
  pf_bind=$(curl --insecure --get --silent --show-error \
      --retry $curl_retry --retry-delay $curl_retry_delay --max-time $curl_max_time \
      --data-urlencode "payload=$pf_payload" \
      --data-urlencode "signature=$pf_getsignature" \
      $verify \
      "https://$pf_host:19999/bindPort")
  if [ "$(echo $pf_bind | jq -r .status)" != "OK" ]; then
    echo "$(date): bindPort error"
    echo $pf_bind
    fatal_error
  fi
}

get_sig () {
  pf_getsig=$(curl --insecure --get --silent --show-error \
    --retry $curl_retry --retry-delay $curl_retry_delay --max-time $curl_max_time \
    --data-urlencode "token=$tok" \
    $verify \
    "https://$pf_host:19999/getSignature")
  if [ "$(echo $pf_getsig | jq -r .status)" != "OK" ]; then
    echo "$(date): getSignature error"
    echo $pf_getsig
    fatal_error
  fi
  pf_payload=$(echo $pf_getsig | jq -r .payload)
  pf_getsignature=$(echo $pf_getsig | jq -r .signature)
  pf_port=$(echo $pf_payload | base64 -d | jq -r .port)
  pf_token_expiry_raw=$(echo $pf_payload | base64 -d | jq -r .expires_at)
  if date --help 2>&1 /dev/null | grep -i 'busybox' > /dev/null; then
    pf_token_expiry=$(date -D %Y-%m-%dT%H:%M:%S --date="$pf_token_expiry_raw" +%s)
  else
    pf_token_expiry=$(date --date="$pf_token_expiry_raw" +%s)
  fi
}

pf_port () {
  # Get current NAT port number using xmlstarlet to parse the config file.
  CURPORT=`cat $CONFFILE | grep PortRangeMin | cut -d\= -f2`
  echo "Current Port: $CURPORT"
  echo "pia-port: Current port forward: $CURPORT"
  # The port mapping doesn't always change.
  # We don't want to force pfSense to re-read it's config if we don't need to.
  if [ "$CURPORT" = "$pf_port" ]; then
        echo "pia-port: Current Port: $CURPORT, PIA Port: $pf_port - Port not changed. Exiting."
        # Create the pia_port file, as it's possible it could have been
        # removed by external means.
        echo $pf_port > /config/pia_port.txt
  else
        # Port forward has changed, so we update the rules in the config file.
        #sed -i.bak 's/^\(download_start_port=\).*/\1'\"$pf_port\"'/' $CONFFILE
        source /etc/qbittorrent/qbittorrent.init stop
        sleep 5
        sed -i.bak 's/^\(Connection\\PortRangeMin=\).*/\1'$pf_port'/' $CONFFILE
        echo "pia-port: New port number ($pf_port) inserted into config file $CONFFILE."
        #cat $CONFFILE
        # This can then be read by other hosts in order to update the open port in
        # whatever torrent client is in use.
        echo $pf_port > /config/pia_port.txt
        # restart download station to use new port
        #PUID=0 PGID=0 /etc/qbittorrent/qbittorrent.init restart
        source /etc/qbittorrent/qbittorrent.init start
        #/usr/syno/bin/synopkg stop DownloadStation
        #/usr/syno/bin/synopkg start DownloadStation
        #systemctl start qbittorrent
  fi

}

# Rebind every 15 mins (same as desktop app)
pf_bindinterval=$(( 15 * 60))
# Get a new token when the current one has less than this remaining
# Defaults to 7 days (same as desktop app)
pf_minreuse=$(( 60 * 60 * 24 * 7 ))

pf_remaining=0
pf_firstrun=1

while true; do
  echo "starting port forwarding check"
  vpn_ip=$(traceroute -m 1 privateinternetaccess.com | tail -n 1 | awk '{print $2}')
  pf_host="$vpn_ip"
  pf_remaining=$((  $pf_token_expiry - $(date +%s) ))
  # Get a new pf token as the previous one will expire soon
  if [ $pf_remaining -lt $pf_minreuse ]; then
    if [ $pf_firstrun -ne 1 ]; then
      echo "$(date): PF token will expire soon. Getting new one."
    else
      echo "$(date): Getting PF token"
      pf_firstrun=0

    fi
    get_sig
    echo "$(date): Obtained PF token. Expires at $pf_token_expiry_raw"
    bind_port
    echo "$(date): Server accepted PF bind"
    echo "$(date): Forwarding on port $pf_port"
    pf_port
    echo "$(date): Rebind interval: $pf_bindinterval seconds"
  fi
  sleep $pf_bindinterval &
  wait $!

  bind_port

done
