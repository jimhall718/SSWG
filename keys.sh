#!/bin/sh

config_file="/wg/sswg.json"
read_config() {
    conf_json=$(cat "$config_file")
    
    config_folder="$(echo "$conf_json" | jq -r '.config_folder')"
    mkdir $config_folder
    username="$(echo "$conf_json" | jq -r '.username')"
    password="$(echo "$conf_json" | jq -r '.password')"
    baseurl="https://api.surfshark.com"
    token_file="${config_folder}/token.json"
    servers_file="${config_folder}/surfshark_servers.json"
    wg_keys="${config_folder}/wg.json"
    output_conf_folder="${config_folder}/conf"

 unset conf_json
}

do_login () {
    rc=1
    if [ "$1" = "-d" ] || [ -f "$token_file" ]; then
        echo "Token file \"$token_file\" exists, skipping login"  ## With the new "000" Failure in reg_pubkey and do_login...
        rc=0                                                      ## we'er calling out the "000" failure in curl/http...
    else                                                          ## continuing with generation of new/updated "Token.json"!  
        echo "Logging in..."                                      ## Line 129 seems to prevent Line 37 'Curl 000' echo.
        tmpfile=$(mktemp /tmp/wg-curl-res.XXXXXX)
        url="$baseurl/v1/auth/login"
        data="{\"username\":\"$username\", \"password\":\"$password\"}"
        http_status=$(curl -o "$tmpfile" -s -w "%{http_code}" -d "$data" -H 'Content-Type: application/json' -X POST $url)
        if [ "$http_status" -eq 200 ]; then
            cp "$tmpfile" "$token_file"
                echo "  HTTP status OK"
            rc=0
        elif [ "$http_status" -eq 429 ]; then
            echo "  HTTP status $http_status (Blocked! Too many requests, Change VPN Server and Retry)"
        elif [ "$http_status" -eq 000 ]; then                     ## Start do_login at shell script again, "000" is various failure code.
            echo "  Overcoming Curl 000 failure... "
            tmpfile=$(mktemp /tmp/wg-curl-res.XXXXXX)
            url="$baseurl/v1/auth/login"
            data="{\"username\":\"$username\", \"password\":\"$password\"}"
            http_status=$(curl -o "$tmpfile" -s -w "%{http_code}" -d "$data" -H 'Content-Type: application/json' -X POST $url)
            if [ "$http_status" -eq 200 ]; then
                cp "$tmpfile" "$token_file"
                    echo "  HTTP status OK"
            rc=0
            fi                                    
        else
            echo "  HTTP status $http_status (Failed! Check username/password in .json file)"
        # rm -fr "$tmpfile"  
        fi    
    fi
    rm -fr "$tmpfile" 
    if [ "$rc" -eq 0 ]; then
        token="$(jq -r '.token' "$token_file")"
        renewToken="$(jq -r '.renewToken' "$token_file")"
    fi
    return $rc
}

get_servers() {
    echo "Retrieving servers list..."
    tmpfile=$(mktemp /tmp/surfshark-wg-servers.XXXXXXXX)
    url="$baseurl/v4/server/clusters/generic?countryCode="
    http_status=$(curl -o "$tmpfile" -s -w "%{http_code}" -H "Authorization: Bearer $token" -H 'Content-Type: application/json' "$url")
    rc=1
    if [ "$http_status" -eq 200 ]; then
        echo "  HTTP status OK ($(jq '. | length' "$tmpfile") servers downloaded)"
        echo -n "  Selecting available servers..."
        tmpfile2=$(mktemp /tmp/surfshark-wg-servers.XXXXXX)
        jq 'select(any(.[].tags[]; . == "virtual" or . == "p2p" or . == "physical"))' "$tmpfile" | jq -s > "$tmpfile2"   
        echo " ($(jq '. | length' "$tmpfile") servers selected)"
        if [ -f "$servers_file" ]; then
            echo "  Servers list \"$servers_file\" already exists"
            changes=$(diff "$servers_file" "$tmpfile2")
            if [ -z "$changes" ]; then
                echo "  No changes"
                rm -fr "$tmpfile2"
            else
                echo "  Servers changed! Updating servers file" 
                mv "$tmpfile2" "$servers_file"
                rc=0
            fi
        else
            mv "$tmpfile2" "$servers_file"
            rc=0
        fi
    else
            echo "  HTTP status $http_status (Failed)"
    fi
    rm -fr "$tmpfile"
    return $rc
}

gen_keys() {
    if [ "$1" = "-d" ] || [ -f "$wg_keys" ]; then
        echo "WireGuard keys \"$wg_keys\" already exist"
        wg_pub=$(cat "$wg_keys" | jq -r '.pub')
        wg_prv=$(cat "$wg_keys" | jq -r '.prv')
    else
        echo "Generating WireGuard keys..."
        wg_prv=$(wg genkey)
        wg_pub=$(echo "$wg_prv" | wg pubkey)
        echo "{\"pub\":\"$wg_pub\", \"prv\":\"$wg_prv\"}" > "$wg_keys"
    fi
    echo "  Using public key: $wg_pub"
}

reg_pubkey() {
    echo "Registering public key..."
    url="$baseurl/v1/account/users/public-keys"
    data="{\"pubKey\": \"$wg_pub\"}"
    retry=$2

    tmpfile="$(mktemp /tmp/wg-curl-res.XXXXXX)"
    http_status="$(curl -o "$tmpfile" -s -w "%{http_code}" -H "Authorization: Bearer $token" -H "Content-Type: application/json" -d "$data" -X POST $url)"
    message="$(jq -r '.message' "$tmpfile" 2>/dev/null)"
    if [ "$http_status" -eq 201 ]; then
        echo "  New Token " ### The meaning behind 201 status
        echo "  OK (expires: $(jq -r '.expiresAt' "$tmpfile"), id: $(jq -r '.id' "$tmpfile"))"
    elif [ "$http_status" -eq 401 ]; then  ### Changed this to 000 from a http 401 Testing the generic Curl error for reg pubkey as redundancy.
        echo "  Access denied: $message"
        echo "  Token file corrupted! Deleting, and attempting to Login..."     ## Forged a Token to Prompt This echo 
                 rm "$token_file"                                               ## Added these 5 line to del/do_login and get new token
                        if do_login; then
                        reg_pubkey 0
                        return
                        fi
        elif [ "$http_status" -eq 000 ]; then                                   ## Start do_login at shell script again, "000" is various failure code.
            echo "  Overcoming Http 000 failure... "
            rm "$tmpfile"  # Remove Null temp
            tmpfile=$(mktemp /tmp/wg-curl-res.XXXXXX)
            url="$baseurl/v1/auth/login"
            data="{\"username\":\"$username\", \"password\":\"$password\"}"
            http_status=$(curl -o "$tmpfile" -s -w "%{http_code}" -d "$data" -H 'Content-Type: application/json' -X POST $url)
            if [ "$http_status" -eq 200 ]; then
                mv "$tmpfile" "$token_file"
                    echo "  HTTP status OK"
                    reg_pubkey 0
            rc=0
            fi

        if [ "$message" = "Expired JWT Token" ]; then            
            echo "  Deleting $token_file to try again!"
            rm "$token_file"
            if do_login; then
                reg_pubkey 0
                return
            else
                echo "  Giving up..."   ### Have not seen lines 190~ 199 yet
            fi
            rm -fr "$tmpfile"
        elif [ "$message" = "JWT Token not found" ]; then
            echo "  Deleting $token_file to try again!"
            rm "$token_file"
            if do_login; then
                reg_pubkey 0
                return
            else
                echo "  Giving up..."   ### Have not seen lines 190~ 199 yet
            fi
        elif [ "$message" = "JWT Token not found" ]; then
            if [ "$retry" -eq 1 ]; then
                 echo "  Have some coffee and try again!"  
                 sleep 5
                 reg_pubkey 0
                 return
            else
                echo "  Giving up..."
            fi
        
         fi
    elif [ "$http_status" -eq 409 ]; then
        echo "  Already registered"
        url="$baseurl/v1/account/users/public-keys/validate"
        http_status="$(curl -o "$tmpfile" -s -w "%{http_code}" -H "Authorization: Bearer $token" -H "Content-Type: application/json" -d "$data" -X POST $url)"
        if [ "$http_status" -eq 200 ]; then
            expire_date="$(jq -r '.expiresAt' "$tmpfile")"
            ed="$(date -u -d "$expire_date" -D "%Y-%m-%dT%T" +"%s")"
            now="$(date -u +"%s")"
            diff=$((ed - now))
            if [ $diff -eq 604800 ] || [ $((604800 - diff)) -lt 10 ]; then
                echo "  Renewed! (expires: $expire_date)"
                echo "  Hello World Wide WireGuard©"                                          # Your Custom Shout Out 
                echo "  Thanks Jason A. Donenfeld"                                             # wg was written by One Json we can find
                logger -t BOSSUSER "RUN DATE:$(date)   KEYS EXPIRE ON: ${expire_date}"         # Log Status Information

            elif [ $diff -gt 0 ]; then
                echo "  Expires on $expire_date)"
            else
                echo "  Warning: key is expired! ($expire_date)"
            fi
        else
            echo " HTTP status $http_status, failed to check key: $(cat "$tmpfile")"
        fi
    else
        echo "  Failed: HTTP $http_status, $(cat "$tmpfile")"
    fi
    rm -fr "$tmpfile"
}

wg0_new() {
        gen_keys
        do_login
        reg_pubkey
        get_servers
        gen_client_confs
        echo ""
        echo " New Setup Established: Interface "wg0" and Toronto peer "
        echo " Finalized: Allow time for network route to settle in ~ 15 sec "
        echo " Type 'ifdown wg0' to Surf ISP "
        echo " Type 'ifup wg0' to Surf Shark "
        echo " Type 'wg show' Shows the current configuration and device information "
        uci set network.wg0=interface
        uci set network.wg0.proto='wireguard'
        uci set network.wg0.listen_port='51820'
        uci set network.wg0.addresses='10.14.0.2/8'
        uci set network.wg0.peerdns='0'
        uci add_list network.wg0.dns='162.252.172.57'
        uci add_list network.wg0.dns='149.154.159.92'
        uci set network.wg0.private_key=$(eval echo $(jq '.prv' ${wg_keys}))
        uci set network.peertorc='wireguard_wg0'
        uci set network.peertorc.description=peertorc
        uci set network.peertorc.public_key=Nw5CG5BOvqb8GXVEKLOo7v3gGvP7WaUYlJT++c3c31g=
        uci add_list network.peertorc.allowed_ips='::/0'
        uci add_list network.peertorc.allowed_ips='0.0.0.0/0'
        uci set network.peertorc.route_allowed_ips='1'
        uci set network.peertorc.endpoint_host=us-las.prod.surfshark.com
        uci set network.peertorc.endpoint_port='51820'
        uci set network.peertorc.persistent_keepalive='25'
        uci del firewall.cfg03dc81.network
        uci add_list firewall.cfg03dc81.network='wan'
        uci add_list firewall.cfg03dc81.network='wg0'
        uci commit network;uci commit firewall;/etc/init.d/network restart
        echo ""
        echo " : Visit : https://dnscheck.tools/ "
        echo ""
        echo " Type 'wg show' : Must see 'Handshake' and 'Transfer'! "
        echo " -------------"
        echo ""
}

reset_keys() {
        do_login=0
        gen_keys=0
        echo ""
        echo " 'wg0' : UNINSTALLED : DEFAULT ROUTE RESTORED  "
        rm -fr ${config_folder}/token.json
        rm -fr ${config_folder}/surfshark_servers.json
        rm -fr ${config_folder}/wg.json
        rm -fr ${config_folder}/conf
        # /etc/config/firewall
        uci del firewall.cfg02dc81.network
        uci add_list firewall.cfg02dc81.network='lan'
        uci del firewall.cfg03dc81.network
        uci add_list firewall.cfg03dc81.network='wan'
        # /etc/config/network
        uci del network.peertorc
        uci del network.wg0
        uci commit network;uci commit firewall;/etc/init.d/network restart
}

gen_client_confs() {
    postf=".surfshark.com"
    mkdir -p "$output_conf_folder"
    server_hosts="$(cat "$servers_file" | jq -c '.[] | .[] | [.connectionName, .pubKey]'|sort)"
    for row in $server_hosts; do
        srv_host="$(echo "$row" | jq '.[0]')"
        srv_host=$(eval echo "$srv_host")
        srv_pub="$(echo "$row" | jq '.[1]')"
        srv_pub=$(eval echo "$srv_pub")
        echo "generating config for $srv_host"
        srv_conf_file="${output_conf_folder}/${srv_host%"$postf"}.conf"
        srv_conf="[Interface]\nPrivateKey=$wg_prv\nAddress=10.14.0.2/8\nMTU=1350\n\n[Peer]\nPublicKey=o07k/2dsaQkLLSR0dCI/FUd3FLik/F/HBBcOGUkNQGo=\nAllowedIPs=172.16.0.36/32\nEndpoint=wgs.prod.surfshark.com:51820\nPersistentKeepalive=25\n\n[Peer]\nPublicKey=$srv_pub\nAllowedIPs=0.0.0.0/0\nEndpoint=$srv_host:51820\nPersistentKeepalive=25\n"
        uci_conf=""
        if [ "$(echo -e)" = "-e" ]; then
            echo "$srv_conf" > "$srv_conf_file"
        else
            echo -e "$srv_conf" > "$srv_conf_file"
        fi
    done
}

rotate_server() {
    server_hosts="$(cat "$servers_file" | jq -c '.[] | .[] | [.connectionName, .pubKey]'|sort)"
    prefix=$1
    first_match=""
    first_noprefix=""
    first_inlist=""
    echo "Rotating to next server matching a prefix_filter of $prefix"
    #zzz
    #current_server="us-stl.prod.surfshark.com"
    current_server="$(uci get network.peertorc.endpoint_host)"
    echo "The current server is $current_server"
    echo "Please wait this can take a few minutes..."
    for row in $server_hosts; do                                     
        srv_host="$(echo "$row" | jq '.[0]')"                       
        srv_host=$(eval echo "$srv_host")                           
        srv_pub="$(echo "$row" | jq '.[1]')"                        
        srv_pub=$(eval echo "$srv_pub")                                                                                      
        if [[ "$prefix" == "" ]]; then
                      if [[ "$first_noprefix" == "" ]]; then                                                                 
                                first_noprefix="${srv_host}"                                                                    
                                #echo "srv_host = $srv_host"
                                #echo "fnp = $first_noprefix"
                      fi                                                                                               
 
                if [[ "$previous_server" == "$current_server" ]]; then
                     new_server=$srv_host
                fi
        else
                if [[ "$srv_host"   == "$prefix*" ]]; then
                        #echo "$srv_host is a match to $prefix  <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<"                                                
                        if [[ "$first_match" == "" ]]; then
                                first_match=$srv_host
                        fi
                        if [[ "$previous_match" == "$current_server" ]]; then
                                new_server=$srv_host
                                #echo "new server assigned $srv_host   >>>>>>>>>>>>>>>>>>>>>"
                        fi 
                        previous_match=$srv_host
                else
                        #echo "$srv_host DOES NOT MATCH the filter"
                        if [[ "$first_inlist" == "" ]]; then
                                first_inlist=$srv_host
                        fi
                fi
        fi
       ccs=`echo $current_server | cut -f1 -d.`   
       pps=`echo $previous_server | cut -f1 -d.`   
       ppm=`echo $previous_match | cut -f1 -d.`   
       nns=`echo $new_server | cut -f1 -d.`   
       ssh=`echo $srv_host | cut -f1 -d.`   
       ffm=`echo $first_match | cut -f1 -d.`  
        previous_server=$srv_host 
    done                         
    # if the current server was never matched, the new server should be first_match

    # if there was no match to current, or only one match to prefix, new_server is still null
    if [[ "$new_server" == "" ]]; then
        if [[ "$prefix" == "" ]]; then
                new_server=$first_noprefix
        else
                if [[ "$first_match" == "" ]]; then
                        new_server=$first_inlist 
                else
                        new_server=$first_match  
                fi
        fi
        #echo "last chance, new server assigned $new_server   >>>>>>>>>>>>>>>>>>>>>" 
    fi

    # 
        ccs=`echo $current_server | cut -f1 -d.`                                                                                          
       pps=`echo $previous_server | cut -f1 -d.`                                                          
       ppm=`echo $previous_match | cut -f1 -d.`                                                           
       nns=`echo $new_server | cut -f1 -d.`                                                               
       ssh=`echo $srv_host | cut -f1 -d.`                                                                 
    ffm=`echo $first_match | cut -f1 -d.`   
   fnp=`echo $first_noprefix | cut -f1 -d.`    
        #previous_server=$srv_host   
   #echo `type $server_hosts`
   #echo "server_hosts = $server_hosts"
   #new_row="$(echo ${server_hosts} | grep ${new_server} |  head -n 1)"
   #echo "new_row = $new_row"
   #new_pub="$(echo "$new_row" | jq '.[1]')"
   #echo "new_pub = $new_pub"

   for row in $server_hosts; do              
        srv_host="$(echo "$row" | jq '.[0]')"
        srv_host=$(eval echo "$srv_host")   
        srv_pub="$(echo "$row" | jq '.[1]')"
        srv_pub=$(eval echo "$srv_pub")        
        #echo "${srv_host},${srv_pub}"                    
        if [[ $srv_host == $new_server ]]; then
                new_pub=$srv_pub
        fi
    done           
 
   update_server $new_server $new_pub
}

update_server() {
userver=$1
upub=$2
echo "----------- updating to new server  ---------------"
echo "The new server is $userver"
echo "The pubkey is $upub"
# assuming existing config is from sswg keys.sh
# and all works, just need to update server and pubkey
# interface is wg0
# section is peertorc
uci set network.peertorc.public_key=$upub
uci set network.peertorc.endpoint_host=$userver
# restart

uci commit network
ifdown wg0
ifup wg0
#;uci commit firewall;/etc/init.d/network restart



}

list_servers() {                                                                                                                           
    echo "Listing available servers..."
   server_hosts="$(cat "$servers_file" | jq -c '.[] | .[] | [.connectionName, .pubKey]'|sort)"
   echo "connectionName,pubKey"
   echo "---------------------"
   for row in $server_hosts; do
        srv_host="$(echo "$row" | jq '.[0]')"                    
        srv_host=$(eval echo "$srv_host")
        srv_pub="$(echo "$row" | jq '.[1]')"           
        srv_pub=$(eval echo "$srv_pub")                
        echo "${srv_host},${srv_pub}"
    done     
   #echo "$server_hosts"
   echo "---------------------"
                                                                                                                                            
}           


echo ""
echo "   ####           Switch -'option'                ####    "
echo " ____________________________________________________________"
echo ""
echo " '-h'  : eg : $0 -h :Show Help only"
echo " '  '  : eg : $0    :Extend Key Duration "   
echo " '-n'  : eg : $0 -n :New Setup Establish "
echo " '-d'  : eg : $0 -d :Delete 'wg0' and trace settings "
echo " '-g'  : eg : $0 -g :Generate Server conf "
echo " '-l'  : eg : $0 -l :List Servers"
echo " "
echo " '-r'  : eg : $0 -r prefix_filter :rotate vpn connection, filter is optional, can be like 'us-' or 'us-nyc'"
echo "            : to rotate to a specific connection enter specific enough filter such as 'us-nyc'"
echo "            : to rotate to the next connection in a given country, filter on country code such as 'us-'"
echo "            : prefix_filter matches at the beginning of the string, just 'nyc' will fail if name is 'us-nyc'"
echo " ____________________________________________________________"
echo ""
echo "" 
    if [ "$1" = "-h" ]; then                                                                                                                
        exit 0                                                                                                                              
    fi                     
echo " Just a Sec 'ntpdate' sycning clock "    
ntpdate -s 137.184.81.69  ## testing 04052022 : Remark this line if you have not installed ntpdate
echo "Running at $(date)"
read_config

    if [ "$1" = "-d" ]; then
        reset_keys
        exit 1
    fi

gen_keys

if do_login; then
    reg_pubkey 1
else
    echo "Not registering public key!"
fi

    if [ "$1" = "-n" ]; then
        wg0_new
        exit 1
    fi

    if [ "$1" = "-g" ]; then
        get_servers
        gen_client_confs
    fi

    if [ "$1" = "-l" ]; then                                                                                                                
        get_servers                                                                                                                         
        list_servers                                                                                                                     
    fi                                                                                                                                      
                
    if [ "$1" = "-r" ]; then                                                                                                                
        get_servers                                                                                                                         
        rotate_server $2
    fi                                                                                                                                      
            

if [ "$http_status" -eq 429 ] || [ "$http_status" -eq 000 ]; then  ### Added these three line to remind user to change IP; log to system log
        logger -t BOSSUSER "RUN DATE:$(date)   Key Update Failure: if "429" run on different IP and run with -g to get conf's"
        echo "Switching VPN Servers Recommended: (Failed 000 just run again.)  (Failed 429 use different VPN, run again.)"
fi

echo "Done at $(date)"  ## Remark this line if you have not installed ntpdate
echo "Enjoy!"           ## Condidering 
wg show
