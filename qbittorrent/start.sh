#!/bin/bash
if [[ ! -e /config/qBittorrent ]]; then
	mkdir -p /config/qBittorrent/config/
	chown -R ${PUID}:${PGID} /config/qBittorrent
else
	chown -R ${PUID}:${PGID} /config/qBittorrent
fi

if [[ ! -e /config/qBittorrent/config/qBittorrent.conf ]]; then
	/bin/cp /etc/qbittorrent/qBittorrent.conf /config/qBittorrent/config/qBittorrent.conf
	chmod 755 /config/qBittorrent/config/qBittorrent.conf
fi

## Check for missing group
/bin/egrep  -i "^${PGID}:" /etc/passwd
if [ $? -eq 0 ]; then
   echo "Group $PGID exists"
else
   echo "Adding $PGID group"
	 groupadd -g $PGID qbittorent
fi

## Check for missing userid
/bin/egrep  -i "^${PUID}:" /etc/passwd
if [ $? -eq 0 ]; then
   echo "User $PUID exists in /etc/passwd"
else
   echo "Adding $PUID user"
	 useradd -c "qbittorent user" -g $PGID -u $PUID qbittorent
fi

# set umask
export UMASK=$(echo "${UMASK}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')

if [[ ! -z "${UMASK}" ]]; then
  echo "[info] UMASK defined as '${UMASK}'" | ts '%Y-%m-%d %H:%M:%.S'
else
  echo "[warn] UMASK not defined (via -e UMASK), defaulting to '002'" | ts '%Y-%m-%d %H:%M:%.S'
  export UMASK="002"
fi


# Set qBittorrent WebUI and Incoming ports
if [ ! -z "${WEBUI_PORT}" ]; then
	webui_port_exist=$(cat /config/qBittorrent/config/qBittorrent.conf | grep -m 1 'WebUI\\Port='${WEBUI_PORT})
	if [[ -z "${webui_port_exist}" ]]; then
		webui_exist=$(cat /config/qBittorrent/config/qBittorrent.conf | grep -m 1 'WebUI\\Port')
		if [[ ! -z "${webui_exist}" ]]; then
			# Get line number of WebUI Port
			LINE_NUM=$(grep -Fn -m 1 'WebUI\Port' /config/qBittorrent/config/qBittorrent.conf | cut -d: -f 1)
			sed -i "${LINE_NUM}s@.*@WebUI\\Port=${WEBUI_PORT}@" /config/qBittorrent/config/qBittorrent.conf
		else
			echo "WebUI\Port=${WEBUI_PORT}" >> /config/qBittorrent/config/qBittorrent.conf
		fi
	fi
fi

if [ ! -z "${INCOMING_PORT}" ]; then
	incoming_port_exist=$(cat /config/qBittorrent/config/qBittorrent.conf | grep -m 1 'Connection\\PortRangeMin='${INCOMING_PORT})
	if [[ -z "${incoming_port_exist}" ]]; then
		incoming_exist=$(cat /config/qBittorrent/config/qBittorrent.conf | grep -m 1 'Connection\\PortRangeMin')
		if [[ ! -z "${incoming_exist}" ]]; then
			# Get line number of Incoming
			LINE_NUM=$(grep -Fn -m 1 'Connection\PortRangeMin' /config/qBittorrent/config/qBittorrent.conf | cut -d: -f 1)
			sed -i "${LINE_NUM}s@.*@Connection\\PortRangeMin=${INCOMING_PORT}@" /config/qBittorrent/config/qBittorrent.conf
		else
			echo "Connection\PortRangeMin=${INCOMING_PORT}" >> /config/qBittorrent/config/qBittorrent.conf
		fi
	fi
fi

echo "[info] Starting qBittorrent daemon..." | ts '%Y-%m-%d %H:%M:%.S'
/bin/bash /etc/qbittorrent/qbittorrent.init start &
chmod -R 755 /config/qBittorrent

sleep 1
qbpid=$(pgrep -o -x qbittorrent-nox)
echo "[info] qBittorrent PID: $qbpid" | ts '%Y-%m-%d %H:%M:%.S'

export PFWD=$(echo "${PIA_PORT_FORWARD}" | sed 's/"//g' )

if [ -e /proc/$qbpid ]; then
	if [[ -e /config/qBittorrent/data/logs/qbittorrent.log ]]; then
		chmod 775 /config/qBittorrent/data/logs/qbittorrent.log
		if [[ $PFWD == "yes" ]]; then
			echo "[info] PIA Port forwarding configured, calling pia_port_forwarding.sh"
			/bin/bash /etc/openvpn/pia_port_forwarding.sh &
		else
			echo "[info] PIA Port forwarding not enabled"
		fi
	fi
	while true; do
		sleep 120 #check once every couple minutes if VPN is up
		ping -I tun0 -c 10 8.8.8.8 > /dev/null && VPNUP=true || VPNUP=false
		if [[ $VPNUP == false ]]; then
			echo "[crit] VPN down, shutting down docker (turn on auto restart to reconnect)" | ts '%Y-%m-%d %H:%M:%.S'
			exit 5
		fi
		pidof qbittorrent-nox >& /dev/null
		if [[ $? -ne 0 ]]; then 
			sleep 10 #check again after 10 secs.. maybe we were just restarting service to get new port forward
			pidof qbittorrent-nox >& /dev/null
			if [[ $? -ne 0 ]]; then 
				echo "[crit] qbittorrent stopped, shutting down docker (turn on auto restart to reconnect)" | ts '%Y-%m-%d %H:%M:%.S'
				exit 6
			fi
		fi
	done
else
	echo "qBittorrent failed to start!"
fi
