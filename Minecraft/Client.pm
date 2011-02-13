# Minecraft::Client, a _very_ simplistic bot for Minecraft.
#
#

package Minecraft::Client;
use Carp;
use IO::Socket;
use IO::Select;

my $PROTOCOL_VERSION = 8;
my $CLIENT_VERSION = 99;



my(%PACKET_ID_TO_STRING) = (
	0x00 => "keepalive",
	0x01 => "login",
	0x02 => "handshake",
	0x03 => "Chat Message",
	0x04 => "Time Update",
	0x05 => "Entity Equipment",
	0x06 => "Spawn Position",
	0x07 => "Use Entity?",
	0x08 => "Update Health",
	0x09 => "Respawn",
	0x0A => "Player",
	0x0B => "Player Position",
	0x0C => "Player Look",
	0x0D => "Player Position & Look",
	0x0E => "Player Digging",
	0x0F => "Player Block Placement",
	0x10 => "Holding Change",
	0x12 => "Animation",
	0x13 => "Entity Action ???",
	0x14 => "Named Entity Spawn",
	0x15 => "Pickup Spawn",
	0x16 => "Collect Item",
	0x17 => "Add Object/Vehicle",
	0x18 => "Mob Spawn",
	0x19 => "Entity: Painting",
	0x1C => "Entity Velocity?",
	0x1D => "Destroy Entity",
	0x1E => "Entity",
	0x1F => "Entity Relative Move",
	0x20 => "Entity Look",
	0x21 => "Entity Look and Relative Move",
	0x22 => "Entity Teleport",
	0x26 => "Entity Status?",
	0x27 => "Attach Entity?",
	0x28 => "Entity Metadata",
	0x32 => "Pre-Chunk",
	0x33 => "Map Chunk",
	0x34 => "Multi Block Change",
	0x35 => "Block Change",
	0x36 => "Play Note Block",
	0x3C => "Explosion",
	0x64 => "Open window",
	0x65 => "Close window",
	0x66 => "Window click",
	0x67 => "Set slot",
	0x68 => "Window items",
	0x69 => "Update progress bar",
	0x6A => "Transaction",
	0x82 => "Update Sign",
	0xFF => "Disconnect/Kick",
);

my %RECV_PACKET_JUMP_TABLE = (
	0x00 => \&recv_keepalive,
	0x01 => \&recv_login,
	0x02 => \&recv_handshake,
	0x04 => \&recv_time,
	0x06 => \&recv_spawn_position,
	0x07 => \&recv_use_entity,
	0x08 => \&recv_health,
	0x0a => \&recv_player,
	0x0d => \&recv_player_position_and_look,
	0x10 => \&recv_holding_change,
	0x14 => \&recv_named_entity_spawn,
	0x15 => \&recv_pickup_spawn,
	0x18 => \&recv_mob_spawn,
	0x1c => \&recv_entity_velocity,
	0x1d => \&recv_destroy_entity,
	0x1e => \&recv_entity,
	0x1f => \&recv_entity_relative_move,
	0x20 => \&recv_entity_look,
	0x21 => \&recv_entity_look_and_relative_move,
	0x26 => \&recv_entity_status,
	0x28 => \&recv_entity_metadata,
	0x32 => \&recv_pre_chunk,
	0x33 => \&recv_chunk,
	0x34 => \&recv_multi_block_change,
	0x35 => \&recv_block_change,
	0x67 => \&recv_set_slot,
	0x68 => \&recv_window_items,
	0xff => \&recv_disconnect,
);

sub new {
	my $class = shift;
	my($server_name, $server_port, $username, $password) = @_;
	$server_port ||= 25565; # default port
	if(defined $password and not defined $username) {
		croak "Specifying a password but not a username to MinecraftBot::new is nonsensical.";
	}
	$username ||= "AnonymousBot".int(rand(1000000));

	my $self = {
		username => $username,
		sessionid => undef, # Not logged in
		server_name => $server_name,
		server_port => $server_port,
	};
	bless($self, $class);

	# If a password was provided, log into minecraft.net
	if(defined $password) {
		my $sessiondata = mcauth_startsession($username, $password);
		if(not defined $sessiondata) {
			die "Unable to login to minecraft.net as '$username'";
		}
		$self->{'sessionid'} = $sessiondata->{session_id};
		$self->{'username'} = $sessiondata->{username};
	}

	# Log into the server proper
	$self->{'socket'} = IO::Socket::INET->new(
		Proto => "tcp",
		PeerAddr => $server_name,
		PeerPort => $server_port)
		or die "Unable to connect to $server_name:$server_port: $!";
	$self->send_handshake();
	my($type, $hash) = $self->recv_packet();
	if($type ne 'handshake') {
		die "Server failed to reply with a handshake: $type";
	}

	if($hash eq '+') {
		die "Server asked for server password. Not supported.";
	}

	if($hash ne '-') {
		my $MAX_TRIES = 5;
		my $result;
		for(my $tries = 0; $tries < $MAX_TRIES; $tries++) {
			$result = mcauth_joinserver($self->{'username'},
				$self->{'sessionid'}, $hash);
			last if $result eq 'OK';
			print STDERR "minecraft.net rejected, trying again\n";
			sleep 1;
		}
		if($result ne 'OK') {
			die "minecraft.net ejected out server join request: $result";
		}
	}

	$self->send_login();
	($type) = $self->recv_packet();
	if($type ne 'login') {
		die "Server failed to reply with a login: $type";
	}

	return $self;
}

sub pump_and_burn {
	my $self = shift;
	my $MAX_MESSAGES = 10;
	for(my $num_processed = 0; $num_processed < $MAX_MESSAGES; $num_processed++) {
		my $socket = $self->{'socket'};
		my @ready = IO::Select->new($socket)->can_read(0);
		if(@ready == 0) { return 0; }
		$self->recv_packet();
	}
	return 1;
}

sub send {
	my $self = shift;
	my $socket = $self->{'socket'};
	print $socket @_;
}

sub send_packet_id {
	my $self = shift;
	my $id = shift;
	$self->debug_sendrecv_off();
	$self->send_sint8($id);
	$self->debug_sendrecv_on();
	my $hexid = sprintf("%02x", $id);
	my $name = $PACKET_ID_TO_STRING{$id} || '';
	$self->debug_send("0x$hexid ($name)");
}

sub send_sint8 {
	my $self = shift;
	$self->debug_send($_[0]);
	$self->send(pack("c", $_[0]));
}

sub send_sint16 {
	my $self = shift;
	$self->debug_send($_[0]);
	# Why this complexity? pack doesn't know how to do signed big-endian. :-/
	$self->send(pack("n", unpack("S", pack("s", $_[0]))));
}

sub send_sint32 {
	my $self = shift;
	$self->debug_send($_[0]);
	# Why this complexity? pack doesn't know how to do signed big-endian. :-/
	$self->send(pack("N", unpack("L", pack("l", $_[0]))));
}

sub send_opaque_float32 {
	my $self = shift;
	$self->debug_send("unknown-float32");
	$self->send($_[0]);
}

sub send_opaque_float64 {
	my $self = shift;
	$self->debug_send("unknown-float64");
	$self->send($_[0]);
}

# At the moment this is a lie. It can only send positive
# integers up to 2^31-1.
sub send_sint64 {
	my $self = shift;
	$self->debug_send($_[0]);
	if($_[0] < 0 || $_[0] > 2147483647) {
		print STDERR "Warning: sending unsupported number!";
	}
	$self->debug_sendrecv_off();
	$self->send_sint32(0);
	$self->send_sint32($_[0]);
	$self->debug_sendrecv_on();
}

sub send_keepalive {
	my $self = shift;
	$self->send_packet_id(0x00);
	$self->debug_sendrecv_force();
}

sub send_string {
	my $self = shift;
	$self->debug_sendrecv_off();
	$self->send_sint16(length $_[0]);
	$self->debug_sendrecv_on();
	$self->send($_[0]);
	$self->debug_send("\"$_[0]\"");
}

sub send_handshake {
	my $self = shift;
	$self->send_packet_id(0x02);
	$self->send_string($self->{'username'});
}

sub send_login {
	my $self = shift;
	my $server_password = shift;
	if(not defined $server_password) { $server_password = ''; }
	$self->send_packet_id(0x01);
	$self->send_sint32($PROTOCOL_VERSION);
	$self->send_string($self->{'username'});
	$self->send_string($server_password);
	$self->send_sint64(0); # map seed, unused in SMP
	$self->send_sint8(0); # dimension, unused in SMP
}

sub send_player_position_and_look {
	my $self = shift;
	$self->send_packet_id(0x0d);
	$self->send_opaque_float64($self->{'position_and_look'}{'x'});
	$self->send_opaque_float64($self->{'position_and_look'}{'stance'});
	$self->send_opaque_float64($self->{'position_and_look'}{'y'});
	$self->send_opaque_float64($self->{'position_and_look'}{'z'});
	$self->send_opaque_float32($self->{'position_and_look'}{'yaw'});
	$self->send_opaque_float32($self->{'position_and_look'}{'pitch'});
	$self->send_sint8($self->{'position_and_look'}{'on_ground'});
	return;
}

sub sysread {
	my $self = shift;
	my $len = shift;
	if($len == 0) { return ''; }
	if($len < 0) {
		$self->debug_sendrecv_force();
		confess("sysread($len): negative length");
	}
	my $socket = $self->{'socket'};
	my $x;
	my $total_read = 0;
	while($total_read < $len) {
		my $len_read = sysread($socket, $x, $len - $total_read);
		if(not defined $len_read) {
			$self->debug_sendrecv_force();
			confess "Unable to read from server: $!";
		}
		if($len_read == 0) {
			$self->debug_sendrecv_force();
			confess "Server closed connection.";
		}
		$total_read += $len_read;
	}
	if($total_read > $len) {
		confess "Somehow read more bytes than requested!";
	}
	return $x;
}

sub recv_burn_blob {
	my $self = shift;
	my $len = shift;
	while($len > 0) {
		my $munch = 128;
		if($munch > $len) { $munch = $len; }
		$len -= $munch;
		$self->sysread($munch);
	}
	if($len < 0) { confess("$len < 0!"); }
}

sub recv_sint8 {
	my $self = shift;
	my $x = $self->sysread(1);
	my $val = unpack('c', $x);
	$self->debug_recv($val);
	return $val;
}

sub recv_uint8 {
	my $self = shift;
	my $x = $self->sysread(1);
	my $val = unpack('C', $x);
	$self->debug_recv($val);
	return $val;
}

sub recv_sint16 {
	my $self = shift;
	my $x = $self->sysread(2);
	my $val = unpack("s", pack("S", unpack("n", $x)));
	$self->debug_recv($val);
	return $val;
}

sub recv_sint32 {
	my $self = shift;
	my $x = $self->sysread(4);
	my $val = unpack("l", pack("L", unpack("N", $x)));
	$self->debug_recv($val);
	return $val;
}

sub recv_burn_sint64 {
	my $self = shift;
	my $x = $self->sysread(4); # high bits. Hope they're 0
	$x = $self->sysread(4); # low bits. Hope they're >= 0
	my $val = unpack("l", pack("L", unpack("N", $x)));
	$self->debug_recv($val);
	$self->debug_recv('ISH');
	return undef;
}

sub recv_opaque_float32 {
	my $self = shift;
	my $x = $self->sysread(4);
	$val = unpack("f", $x);
	$self->debug_recv("float(maybe $val)");
	return $x;
}

sub recv_opaque_float64 {
	my $self = shift;
	my $x = $self->sysread(8);
	$self->debug_recv("double");
	return $x;
}

sub recv_string {
	my $self = shift;
	$self->debug_sendrecv_off();
	my $len = $self->recv_sint16();
	$self->debug_sendrecv_on();
	if($len < 0) {
		$self->debug_sendrecv_force();
		confess "Server claims to be sending me a $len byte long string.";
	}
	my $str = $self->sysread($len);
	$self->debug_recv($str);
	return $str;
}

sub recv_burn_metadata {
	my $self = shift;
	$self->debug_recv('metadata(');
	while(1) {
		my $type = $self->recv_sint8();
		if($type == 127) { last; }
		if   ($type == 0) { $self->recv_sint8(); }
		elsif($type == 1) { $self->recv_sint16(); }
		elsif($type == 2) { $self->recv_sint32(); }
		elsif($type == 3) { $self->recv_opaque_float32(); }
		elsif($type == 4) { $self->recv_string(); }
		elsif($type == 5) {
			$self->recv_sint16();
			$self->recv_sint8();
			$self->recv_sint16();
		} elsif($type == 16) { $self->recv_sint8(); }
		else {
			$self->debug_recv('MORE');
			for(my $i = 0; $i < 32; $i++) {
				$self->debug_sendrecv_off();
				my $x = $self->recv_sint8();
				$self->debug_sendrecv_on();
				my $hex = sprintf("%02x", $x);
				$self->debug_recv($hex);
			}
			$self->debug_sendrecv_force();
			die "Unknown metadata type $type";
		}
	}
	$self->debug_recv(')');
}

sub recv_packet_id {
	my $self = shift;
	$self->debug_sendrecv_off();
	my $id = $self->recv_uint8();
	$self->debug_sendrecv_on();
	my $name = $PACKET_ID_TO_STRING{$id} || '';
	my $hexid = sprintf("%02x", $id);
	$self->debug_recv("0x$hexid ($name)");
	return $id;
}

sub recv_packet {
	my $self = shift;
	my $id = $self->recv_packet_id();
	if(exists $RECV_PACKET_JUMP_TABLE{$id}) {
		my(@ret) = $RECV_PACKET_JUMP_TABLE{$id}($self, $id);
		$self->debug_sendrecv_force();
		return ($PACKET_ID_TO_STRING{$id}, @ret);
	} else {
		my $name = $PACKET_ID_TO_STRING{$id} || '';
		for(my $i = 0; $i < 32; $i++) {
			$self->debug_sendrecv_off();
			my $x = $self->recv_sint8();
			$self->debug_sendrecv_on();
			my $hex = sprintf("%02x", $x);
			$self->debug_recv($hex);
		}
		$self->debug_sendrecv_force();
		my $hexid = sprintf("0x%02x", $id);
		die "Received unexpected packet id $hexid $name";
	}
}

sub recv_keepalive {
	# we don't actually need to bind sending keepalives to receiving them,
	# but it's a simple solution to the problem.
	$_[0]->send_keepalive();
} 

sub recv_handshake {
	my $self = shift;
	my $hash = $self->recv_string();
	# could be +, -, or a hash
	return($hash);
}

sub recv_time {
	my $self = shift;
	$self->recv_burn_sint64();
	return;
}

sub recv_login {
	my $self = shift;
	my $entity_id = $self->recv_sint32();
	my $server_str_1 = $self->recv_string();
	my $server_str_2 = $self->recv_string();
	$self->recv_burn_sint64(); # Map seed.
	my $dimension = $self->recv_sint8();
	$self->{'entity_id'} = $entity_id;
	$self->{'server_str_1'} = $server_str_1;
	$self->{'server_str_2'} = $server_str_2;
	$self->{'dimension'} = $dimension;
	return;
}

sub recv_spawn_position {
	my $self = shift;
	$self->{'spawn'}{'x'} = $self->recv_sint32();
	$self->{'spawn'}{'y'} = $self->recv_sint32();
	$self->{'spawn'}{'z'} = $self->recv_sint32();
	return;
}

sub recv_use_entity {
	my $self = shift;
	$self->recv_sint32(); # user
	$self->recv_sint32(); # target
	$self->recv_sint8(); # left-click?
	return;
}

sub recv_health {
	my $self = shift;
	$self->recv_sint16();
	return;
}

sub recv_player_position_and_look {
	my $self = shift;
	$self->{'position_and_look'}{'x'} = $self->recv_opaque_float64();
	$self->{'position_and_look'}{'y'}= $self->recv_opaque_float64();
	$self->{'position_and_look'}{'stance'}= $self->recv_opaque_float64();
	$self->{'position_and_look'}{'z'} = $self->recv_opaque_float64();
	$self->{'position_and_look'}{'yaw'} = $self->recv_opaque_float32();
	$self->{'position_and_look'}{'pitch'} = $self->recv_opaque_float32();
	$self->{'position_and_look'}{'on_ground'} = $self->recv_sint8();

	# We need to immediately reply confirming the position.
	# Failure to do so can get the server cranky at us.
	$self->send_player_position_and_look();

	return;
}

sub recv_player {
	my $self = shift;
	my $x = $self->recv_sint8(); # on ground?
	$self->{'position_and_look'}{'on_ground'} = $x;
	return;
}

sub recv_holding_change {
	my $self = shift;
	$self->recv_sint16(); # slot
	return;
}

sub recv_named_entity_spawn {
	my $self = shift;
	$self->recv_sint32(); # entity ID
	$self->recv_string(); # Player Name
	$self->recv_sint32(); # X
	$self->recv_sint32(); # Y
	$self->recv_sint32(); # Z
	$self->recv_sint8(); # rotation
	$self->recv_sint8(); # pitch
	$self->recv_sint16(); # current item
}

sub recv_pickup_spawn {
	my $self = shift;
	$self->recv_sint32(); # entity ID
	$self->recv_sint16(); # item ID
	$self->recv_sint8(); # count
	$self->recv_sint16(); # damage/data
	$self->recv_sint32(); # x
	$self->recv_sint32(); # y
	$self->recv_sint32(); # z
	$self->recv_sint8(); # rotation
	$self->recv_sint8(); # pitch
	$self->recv_sint8(); # roll
	return;
}

sub recv_mob_spawn {
	my $self = shift;
	$self->recv_sint32(); # entity ID
	$self->recv_sint8(); # type
	$self->recv_sint32(); # x
	$self->recv_sint32(); # y
	$self->recv_sint32(); # z
	$self->recv_sint8(); # yaw
	$self->recv_sint8(); # pitch
	$self->recv_burn_metadata();
	return;
}

sub recv_entity_velocity {
	my $self = shift;
	$self->recv_sint32(); # entity ID
	$self->recv_sint16(); # x
	$self->recv_sint16(); # y
	$self->recv_sint16(); # z
	return;
}

sub recv_destroy_entity {
	my $self = shift;
	$self->recv_sint32(); # entity ID
}

sub recv_entity {
	my $self = shift;
	$self->recv_sint32(); # entity ID
}

sub recv_entity_relative_move {
	my $self = shift;
	$self->recv_sint32(); # entity ID
	$self->recv_sint8(); # dx
	$self->recv_sint8(); # dy
	$self->recv_sint8(); # dz
}

sub recv_entity_look {
	my $self = shift;
	$self->recv_sint32(); # entity ID
	$self->recv_sint8(); # yaw
	$self->recv_sint8(); # pitch
}

sub recv_entity_look_and_relative_move {
	my $self = shift;
	$self->recv_sint32(); # entity ID
	$self->recv_sint8(); # dx
	$self->recv_sint8(); # dy
	$self->recv_sint8(); # dz
	$self->recv_sint8(); # yaw
	$self->recv_sint8(); # pitch
}

sub recv_entity_status {
	my $self = shift;
	$self->recv_sint32(); # entity ID
	$self->recv_sint8(); # status
}

sub recv_entity_metadata {
	my $self = shift;
	$self->recv_sint32(); # entity ID
	$self->recv_burn_metadata();
}

sub recv_pre_chunk {
	my $self = shift;
	$self->recv_sint32(); # x
	$self->recv_sint32(); # y
	$self->recv_sint8(); # mode
}

sub recv_chunk {
	my $self = shift;
	$self->recv_sint32(); # x
	$self->recv_sint16(); # y
	$self->recv_sint32(); # z
	$self->recv_sint8(); # dx
	$self->recv_sint8(); # dy
	$self->recv_sint8(); # dz
	my $data_len = $self->recv_sint32();
	$self->recv_burn_blob($data_len); # compressed data.
}

sub recv_multi_block_change {
	my $self = shift;
	$self->recv_sint32(); # x
	$self->recv_sint32(); # z
	my $data_len = $self->recv_sint16();
	for(my $i = 0; $i < $data_len; $i++) { $self->recv_sint16(); } # coordinate
	for(my $i = 0; $i < $data_len; $i++) { $self->recv_sint8(); } # type
	for(my $i = 0; $i < $data_len; $i++) { $self->recv_sint8(); } # meta
}

sub recv_block_change {
	my $self = shift;
	$self->recv_sint32(); # x
	$self->recv_sint8(); # y
	$self->recv_sint32(); # z
	$self->recv_sint8(); # type
	$self->recv_sint8(); # meta
}

sub recv_set_slot {
	my $self = shift;
	$self->recv_sint8(); # window id
	$self->recv_sint16(); # slot
	my $id = $self->recv_sint16(); # item id
	if($id != -1) {
		$self->recv_sint8(); # count
		$self->recv_sint16(); # Times used
	}
}

sub recv_window_items {
	my $self = shift;
	$self->recv_sint8(); # window id
	my $count = $self->recv_sint16();
	for(my $i = 0; $i < $count; $i++) {
		my $id = $self->recv_sint16(); # item id
		if($id != -1) { # Real
			$self->recv_sint8(); # Count
			$self->recv_sint16(); # Times used
		} else { # empty
		}

	}
}

sub recv_disconnect {
	my $self = shift;

	$self->debug_sendrecv_off();
	my $len = $self->recv_sint16();
	$self->debug_sendrecv_on();
	my $reason;
	if($len < 0) {
		$reason = "Server hates me, claims length of $len bytes";
	} else {
		$reason = $self->sysread($len);
		$self->debug_recv($str);
	}
	$self->debug_sendrecv_force();
	close($self->{socket});
	die "Server $self->{server_name}:$self-{server_port} kicked us off: $reason.";
}

sub debug {
	my $self = shift;
	print STDERR @_;
}

sub debug_sendrecv_force {
	my $self = shift;
	if(exists $self->{'debug_sendrecv_msg'}) {
		$self->debug("$self->{'debug_sendrecv_prefix'}$self->{'debug_sendrecv_msg'}\n");
	}
	delete $self->{'debug_sendrecv_msg'};
	delete $self->{'debug_sendrecv_prefix'};
}

sub debug_sendrecv {
	my $self = shift;
	my $prefix = shift;

	if($self->{'debug_sendrecv_paused'}) { return; }

	if(exists $self->{'debug_sendrecv_prefix'} and $self->{'debug_sendrecv_prefix'} ne $prefix) {
		$self->debug_sendrecv_force();
	}

	$self->{'debug_sendrecv_prefix'} = $prefix;
	if(not defined $self->{'debug_sendrecv_msg'}) {
		$self->{'debug_sendrecv_msg'} = '';
	}
	$self->{'debug_sendrecv_msg'} .= " @_";
}

sub debug_sendrecv_off {
	$_[0]->{'debug_sendrecv_paused'} = 1;
}

sub debug_sendrecv_on {
	delete $_[0]->{'debug_sendrecv_paused'};
}

sub debug_send {
	my $self = shift;
	$self->debug_sendrecv('->', @_);
}

sub debug_recv {
	my $self = shift;
	$self->debug_sendrecv('<-', @_);
}

sub mcauth_startsession {
	my @gvd = split(/\:/, http('www.minecraft.net', '/game/getversion.jsp', 'user='.urlenc($_[0]).'&password='.urlenc($_[1]).'&version='.urlenc($CLIENT_VERSION)));
	return join(':', @gvd) if @gvd < 4;
	return {version=>$gvd[0], download_ticket=>$gvd[1], username=>$gvd[2], session_id=>$gvd[3]};
}


sub mcauth_joinserver {
  return http('www.minecraft.net', '/game/joinserver.jsp?user='.urlenc($_[0]).'&sessionId='.urlenc($_[1]).'&serverId='.urlenc($_[2]));
}

sub urlenc {
  local $_ = $_[0];
  s/([^a-zA-Z0-9\ ])/sprintf("%%%02X",ord($1))/ge;
  s/\ /\+/g;
  return $_;
}

sub burst_url {
	my($url) = @_;
	my($proto, $host, $port, $path) = ($url =~ m!(.*?)://([^:/]+)(?::(\d+))?(/.+)!);
	if(not defined $proto) { return; }
	if(not defined $port) { $port = 80; }
	return($proto, $host, $port, $path);
}

sub http {
  my ($host, $path, $post) = @_;

  my $port = 80;

  my $redirect_count = 0;
  my $REDIRECT_LIMIT = 5; # Don't redirect more than this many times.

  while($redirect_count < $REDIRECT_LIMIT) {
    $redirect_count++;

    my $http = IO::Socket::INET->new(
      Proto     => "tcp",
      PeerAddr  => $host,
      PeerPort  => $port,
    ) or die "can't connect to $host:$port for http: $!";

    print $http +(defined $post ? "POST" : "GET")." $path HTTP/1.0\r\nHost: $host\r\n";
    print "\n\n$host:$port ->".(defined $post ? "POST" : "GET")." $path HTTP/1.0\nHost: $host\n";
    if (defined $post) {
      print $http "Content-Length: ".length($post)."\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\n$post";
      print "Content-Length: ".length($post)."\nContent-Type: application/x-www-form-urlencoded\n\n$post";
    } else {
      print $http "\r\n";
      print "\r\n";
    }

    my $response_line = <$http>;
    my($response_code) = ($response_line =~ /HTTP\/\d+\.\d+ (\d+)/);
    if(not defined $response_code) { $response_code = ''; }
    if($response_code == 200) { # OK
      print "\n$response_line";
      while (<$http> =~ /\S/) {}
      my $ret = join("\n", <$http>);
      print $ret;
      return $ret;
    } elsif( $response_code == 300 || $response_code == 301 ||
             $response_code == 302 || $response_code == 303 ||
             $response_code == 307) { # redirected
      my $line;
      while(defined ($line = <$http>) and $line !~ /^Location:/) { }
      if(not defined $line) {
        print "$host indicated redirection, but didn't give a URL\n";
        return;
      }

	  my $old_host = $host;

      my($url) = ($line =~ /^Location:\s*([^\n\r]*)/);
      my $proto;
      ($proto, $host, $port, $path) = burst_url($url);
      if(not defined $proto) {
        print "Unable to parse redirection URL from $old_host: $url\n";
        return;
      }
      if($proto ne 'http') {
        print "Non-HTTP protocol in redirection URL from $old_host not supported: $url\n";
        return;
      }
	  # Let the loop continue with the new host, port, path.

    } else {
      print "HTTP request to $host failed: $response_line\n";
      return;
    }
  }
  print "HTTP request redirected $REDIRECT_LIMIT times. Aborting to avoid possible loop.\n";


}

=head1 COPYRIGHT

  Copyright 2011 Alan De Smet

This library is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut

1;
