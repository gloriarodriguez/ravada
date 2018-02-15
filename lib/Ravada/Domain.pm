package Ravada::Domain;

use warnings;
use strict;

=head1 NAME

Ravada::Domain - Domains ( Virtual Machines ) library for Ravada

=cut

use Carp qw(carp confess croak cluck);
use Data::Dumper;
use File::Copy;
use File::Rsync;
use Hash::Util qw(lock_hash);
use Image::Magick;
use JSON::XS;
use Moose::Role;
use Sys::Statistics::Linux;
use IPTables::ChainMgr;

no warnings "experimental::signatures";
use feature qw(signatures);

use Ravada::Domain::Driver;
use Ravada::Utils;

our $TIMEOUT_SHUTDOWN = 20;
our $CONNECTOR;

our $MIN_FREE_MEMORY = 1024*1024;
our $IPTABLES_CHAIN = 'RAVADA';

our %PROPAGATE_FIELD = map { $_ => 1} qw( run_timeout );

_init_connector();

requires 'name';
requires 'remove';
requires 'display';

requires 'is_active';
requires 'is_hibernated';
requires 'is_paused';
requires 'is_removed';

requires 'start';
requires 'shutdown';
requires 'shutdown_now';
requires 'force_shutdown';
requires '_do_force_shutdown';

requires 'pause';
requires 'resume';
requires 'prepare_base';

requires 'rename';

#storage
requires 'add_volume';
requires 'list_volumes';

requires 'disk_device';

requires 'disk_size';

requires 'spinoff_volumes';

requires 'clean_swap_volumes';
#hardware info

requires 'get_info';
requires 'set_memory';
requires 'set_max_mem';

requires 'hybernate';

#remote methods
requires 'migrate';
##########################################################

has 'domain' => (
    isa => 'Any'
    ,is => 'rw'
);

has 'timeout_shutdown' => (
    isa => 'Int'
    ,is => 'ro'
    ,default => $TIMEOUT_SHUTDOWN
);

has 'readonly' => (
    isa => 'Int'
    ,is => 'ro'
    ,default => 0
);

has 'storage' => (
    is => 'ro'
    ,isa => 'Object'
    ,required => 0
);

has '_vm' => (
    is => 'rw',
    ,isa => 'Object'
    ,required => 0
);

has 'tls' => (
    is => 'rw'
    ,isa => 'Int'
    ,default => 0
);

has 'description' => (
    is => 'rw'
    ,isa => 'Str'
    ,required => 0
    ,trigger => \&_update_description
);

##################################################################################3
#


##################################################################################3
#
# Method Modifiers
#

around 'display' => \&_around_display;

around 'add_volume' => \&_around_add_volume;

before 'remove' => \&_pre_remove_domain;
#\&_allow_remove;
 after 'remove' => \&_after_remove_domain;

before 'prepare_base' => \&_pre_prepare_base;
 after 'prepare_base' => \&_post_prepare_base;

before 'start' => \&_start_preconditions;
 after 'start' => \&_post_start;

before 'pause' => \&_allow_manage;
 after 'pause' => \&_post_pause;

before 'hybernate' => \&_allow_manage;
 after 'hybernate' => \&_post_hibernate;

before 'resume' => \&_allow_manage;
 after 'resume' => \&_post_resume;

before 'shutdown' => \&_pre_shutdown;
after 'shutdown' => \&_post_shutdown;

around 'shutdown_now' => \&_around_shutdown_now;
around 'force_shutdown' => \&_around_shutdown_now;

before 'remove_base' => \&_pre_remove_base;
after 'remove_base' => \&_post_remove_base;

before 'rename' => \&_pre_rename;
after 'rename' => \&_post_rename;

before 'clone' => \&_pre_clone;

after 'screenshot' => \&_post_screenshot;

after '_select_domain_db' => \&_post_select_domain_db;

before 'migrate' => \&_pre_migrate;
after 'migrate' => \&_post_migrate;

around 'get_info' => \&_around_get_info;

##################################################
#

sub BUILD {
    my $self = shift;
    $self->_init_connector();

    $self->is_known();
    eval { $self->_check_clean_shutdown() };
#    warn $@ if $@;
}

sub _check_clean_shutdown($self) {
    if ( $self->is_known
        && !$self->readonly
        && $self->_data('status') eq 'active'
        && !$self->is_active ) {
            $self->_post_shutdown();
    }
}

sub _set_last_vm($self,$force=0) {
    my $id_vm;
    $id_vm = $self->_data('id_vm')  if $self->is_known();
    return $self->_set_vm($id_vm, $force)   if $id_vm;
}

sub _set_vm($self, $vm, $force=0) {
    if (!ref($vm)) {
        $vm = Ravada::VM->open($vm);
    }

    my $domain;
    eval { $domain = $vm->search_domain($self->name) };
    die $@ if $@ && $@ !~ /no domain with matching name/;
    if ($domain && ($force || $domain->is_active)) {
        $self->_pre_migrate($vm);
       $self->_vm($vm);
       $self->domain($domain->domain);
        $self->_update_id_vm();
    }
    return $vm->id;

}

sub _check_equal_storage_pools($self, $vm) {
     confess "ERROR: ".$vm->name." and ".$self->_vm->name
        ." have different storage pools "
        .Dumper([$vm->list_storage_pools],[$self->_vm->list_storage_pools])
            if !_equal_storage_pools($vm, $self->_vm);
}

sub _equal_storage_pools($vm1, $vm2) {
    my @sp1 = sort $vm1->list_storage_pools();
    my @sp2 = sort $vm2->list_storage_pools();
    return 0 if scalar @sp1 != scalar @sp2;

    for ( 0 .. $#sp1 ) {
        return 0 if $sp1[$_] ne $sp2[$_];
    }
    return 1;
}

sub _vm_connect {
    my $self = shift;
    $self->_vm->connect();
}

sub _vm_disconnect {
    my $self = shift;
    $self->_vm->disconnect();
}

sub _start_preconditions{
    my ($self) = @_;

    die "Domain ".$self->name." is a base. Bases can't get started.\n"
        if $self->is_base();

    my %args;
    if (scalar @_ %2 ) {
        my @args = @_;
        shift @args;
        %args = @args;
        my $user = delete $args{user};
        my $remote_ip = delete $args{remote_ip};
        confess "ERROR: Unknown argument ".join("," , sort keys %args)
            ."\n\tknown: remote_ip, user"   if keys %args;
        _allow_manage_args(@_);
    } else {
        _allow_manage(@_);
    }

    #TODO: remove them and make it more general now we have nodes
    # $self->_check_free_memory();
    # _check_used_memory(@_);

    return if $self->_search_already_started();
    # if it is a clone ( it is not a base )
    if ($self->id_base) {
#        $self->_set_last_vm(1)
        $self->_balance_vm();
        $self->rsync()  if !$self->_vm->readonly && !$self->_vm->is_local;
    }
}

sub _search_already_started($self) {
    my $sth = $$CONNECTOR->dbh->prepare(
        "SELECT id FROM vms where vm_type=?"
    );
    $sth->execute($self->_vm->type);
    my %started;
    while (my ($id) = $sth->fetchrow) {
        my $vm = Ravada::VM->open($id);
        next if !$vm->is_active;

        my $domain = $vm->search_domain($self->name);
        next if !$domain;
        if ( $domain->is_active || $domain->is_hibernated ) {
            $self->_set_vm($vm,'force');
            $started{$vm->id}++;

            my $status = 'shutdown';
            $status = 'active'  if $domain->is_active;
            $domain->_data(status => $status);
        }
    }
    confess "ERROR: Domain started in ".Dumper(\%started)
        if keys %started > 1;
    return keys %started;
}

sub _balance_vm($self) {
    return if $self->{_migrated};
    return if !$self->id_base;

    my $sth = $$CONNECTOR->dbh->prepare(
        "SELECT id FROM vms where vm_type=?"
    );
    $sth->execute($self->_vm->type);
    my %vm_list;
    for my $vm ($self->_vm->list_nodes) {
        next if !$vm->is_active || $vm->free_memory < $MIN_FREE_MEMORY;
        $vm_list{$vm->id} = scalar($vm->list_domains(active => 1)).".".$vm->free_memory;
    }
    my @sorted_vm = sort { $vm_list{$a} <=> $vm_list{$b} } keys %vm_list;

    my $base = Ravada::Domain->open($self->id_base);
    for my $id (@sorted_vm) {
        if ( $base->base_in_vm($id) ) {
            return if $id == $self->_vm->id;

            my $vm_free = Ravada::VM->open($id);

            $self->migrate($vm_free)    if !$vm_free->is_local;
            return $id;
        }
    }
    return;
}

sub _update_description {
    my $self = shift;

    return if defined $self->description
        && defined $self->_data('description')
        && $self->description eq $self->_data('description');

    my $sth = $$CONNECTOR->dbh->prepare(
        "UPDATE domains SET description=? "
        ." WHERE id=? ");
    $sth->execute($self->description,$self->id);
    $sth->finish;
    $self->{_data}->{description} = $self->{description};
}

sub _allow_manage_args {
    my $self = shift;

    confess "Disabled from read only connection"
        if $self->readonly;

    my %args = @_;

    confess "Missing user arg ".Dumper(\%args)
        if !$args{user} ;

    $self->_allowed($args{user});

}
sub _allow_manage {
    my $self = shift;

    return $self->_allow_manage_args(@_)
        if scalar(@_) % 2 == 0;

    my ($user) = @_;
    return $self->_allow_manage_args( user => $user);

}

sub _allow_remove($self, $user) {

    confess "ERROR: Undefined user" if !defined $user;

    die "ERROR: remove not allowed for user ".$user->name
        if !$user->can_remove();

    $self->_check_has_clones() if $self->is_known();
    if ($self->is_known() && $user->can_remove_clone() && $self->id_base) {
        my $base = $self->open($self->id_base);
        return if $base->id_owner == $user->id;
    }
    $self->_allowed($user);

}

sub _allow_shutdown {
    my $self = shift;
    my %args = @_;

    my $user = $args{user} || confess "ERROR: Missing user arg";

    if ( $self->id_base() && $user->can_shutdown_clone()) {
        my $base = Ravada::Domain->open($self->id_base);
        return if $base->id_owner == $user->id;
    } elsif($user->can_shutdown_all) {
        return;
    } else {
        $self->_allow_manage_args(user => $user);
    }
}

sub _around_add_volume {
    my $orig = shift;
    my $self = shift;
    confess "ERROR in args ".Dumper(\@_)
        if scalar @_ % 2;
    my %args = @_;

    my $path = $args{path};
    if ( $path ) {
        my $name = $args{name};
        if (!$name) {
            ($args{name}) = $path =~ m{.*/(.*)};
        }
    }
    return $self->$orig(%args);
}

sub _pre_prepare_base {
    my $self = shift;
    my ($user, $request) = @_;

    $self->_allowed($user);

    # TODO: if disk is not base and disks have not been modified, do not generate them
    # again, just re-attach them 
#    $self->_check_disk_modified(
    die "ERROR: domain ".$self->name." is already a base" if $self->is_base();
    $self->_check_has_clones();

    $self->is_base(0);
    $self->_post_remove_base();
    if ($self->is_active) {
        $self->shutdown(user => $user);
        for ( 1 .. $TIMEOUT_SHUTDOWN ) {
            last if !$self->is_active;
            sleep 1;
        }
        if ($self->is_active ) {
            $request->status('working'
                    ,"Domain ".$self->name." still active, forcing hard shutdown")
                if $request;
            $self->force_shutdown($user);
            sleep 1;
        }
    }
    if ($self->id_base ) {
        $self->spinoff_volumes();
    }
};

sub _post_prepare_base {
    my $self = shift;

    my ($user) = @_;

    $self->is_base(1);

    if ($self->id_base && !$self->description()) {
        my $base = Ravada::Domain->open($self->id_base);
        $self->description($base->description)  if $base->description();
    }

    $self->_remove_id_base();
    $self->_set_base_vm_db($self->_vm->id,1);
};

sub _check_has_clones {
    my $self = shift;
    return if !$self->is_known();

    my @clones = $self->clones;
    die "Domain ".$self->name." has ".scalar @clones." clones : ".Dumper(\@clones)
        if $#clones>=0;
}

sub _check_free_memory{
    my $self = shift;
    return if ref($self) =~ /Void/i;

    my $lxs  = Sys::Statistics::Linux->new( memstats => 1 );
    my $stat = $lxs->get;
    die "ERROR: No free memory. Only ".int($stat->memstats->{realfree}/1024)
            ." MB out of ".int($MIN_FREE_MEMORY/1024)." MB required." 
        if ( $stat->memstats->{realfree} < $MIN_FREE_MEMORY );
}

sub _check_used_memory {
    my $self = shift;
    my $used_memory = 0;

    my $lxs  = Sys::Statistics::Linux->new( memstats => 1 );
    my $stat = $lxs->get;

    # We get mem total less the used for the system
    my $mem_total = $stat->{memstats}->{memtotal} - 1*1024*1024;

    for my $domain ( $self->_vm->list_domains ) {
        my $alive;
        eval { $alive = 1 if $domain->is_active && !$domain->is_paused };
        next if !$alive;

        my $info = $domain->get_info;
        confess "No info memory ".Dumper($info) if !exists $info->{memory};
        $used_memory += $info->{memory};
    }

    confess "ERROR: Out of free memory. Using $used_memory RAM of $mem_total available" if $used_memory>= $mem_total;
}

=pod

sub _check_disk_modified {
    my $self = shift;

    if ( !$self->is_base() ) {
        return;
    }

    my $last_stat_base = 0;
    for my $file_base ( $self->list_files_base ) {
        my @stat_base = stat($file_base);
        $last_stat_base = $stat_base[9] if$stat_base[9] > $last_stat_base;
#        warn $last_stat_base;
    }

    my $files_updated = 0;
    for my $file ( $self->disk_device ) {
        my @stat = stat($file) or next;
        $files_updated++ if $stat[9] > $last_stat_base;
#        warn "\ncheck\t$file ".$stat[9]."\n vs \tfile_base $last_stat_base $files_updated\n";
    }
    die "Base already created and no disk images updated"
        if !$files_updated;
}

=cut

sub _allowed {
    my $self = shift;

    my ($user) = @_;

    confess "Missing user"  if !defined $user;
    confess "ERROR: User '$user' not class user , it is ".(ref($user) or 'SCALAR')
        if !ref $user || ref($user) !~ /Ravada::Auth/;

    return if $user->is_admin;
    my $id_owner;
    eval { $id_owner = $self->id_owner };
    my $err = $@;

    confess "User ".$user->name." [".$user->id."] not allowed to access ".$self->domain
        ." owned by ".($id_owner or '<UNDEF>')."\n".Dumper($self)
            if (defined $id_owner && $id_owner != $user->id );

    confess $err if $err;

}

sub _around_display($orig,$self,$user) {
    $self->_allowed($user);
    my $display = $self->$orig($user);
    $self->_data(display => $display);
    return $display;
}

sub _around_get_info($orig, $self) {
    my $info = $self->$orig();
    if (ref($self) =~ /^Ravada::Domain/) {
        $self->_data(info => encode_json($info));
    }
    return $info;
}

##################################################################################3

sub _init_connector {
    return if $CONNECTOR && $$CONNECTOR;
    $CONNECTOR = \$Ravada::CONNECTOR if $Ravada::CONNECTOR;
    $CONNECTOR = \$Ravada::Front::CONNECTOR if !defined $$CONNECTOR
                                                && defined $Ravada::Front::CONNECTOR;
}

=head2 id
Returns the id of  the domain
    my $id = $domain->id();
=cut

sub id {
    return $_[0]->_data('id');

}


##################################################################################

sub _data($self, $field, $value=undef) {

    _init_connector();

    if (defined $value) {
        confess "Domain ".$self->name." is not in the DB"
            if !$self->is_known();

        confess "ERROR: Invalid field '$field'"
            if $field !~ /^[a-z]+[a-z0-9_]*$/;

        my $sth = $$CONNECTOR->dbh->prepare(
            "UPDATE domains set $field=? WHERE id=?"
        );
        $sth->execute($value, $self->id);
        $sth->finish;
        $self->{_data}->{$field} = $value;
        $self->_propagate_data($field,$value) if $PROPAGATE_FIELD{$field};
    }
    return $self->{_data}->{$field} if exists $self->{_data}->{$field};
    $self->{_data} = $self->_select_domain_db( name => $self->name);

    confess "No DB info for domain ".$self->name    if !$self->{_data};
    confess "No field $field in domains"            if !exists$self->{_data}->{$field};

    return $self->{_data}->{$field};
}

=head2 open

Open a domain

Argument: id

Returns: Domain object read only

=cut

sub open($class, $id , $readonly = 0) {
    confess "Undefined id"  if !defined $id;
    my $self = {};

    if (ref($class)) {
        $self = $class;
    } else {
        bless $self,$class
    }

    my $row = $self->_select_domain_db ( id => $id );

    die "ERROR: Domain not found id=$id\n"
        if !keys %$row;

    my $vm;
    if ($self->_data('id_vm') && !$self->is_base) {
        $vm = Ravada::VM->open(id => $self->_data('id_vm'), readonly => $readonly);
    }
    if (!$vm || !$vm->is_active) {
        my $vm0 = {};
        my $vm_class = "Ravada::VM::".$row->{vm};
        bless $vm0, $vm_class;

        $vm = $vm0->new( readonly => $readonly );
    }

    my $domain = $vm->search_domain($row->{name});
    return if !$domain;
    $domain->_search_already_started();
    $domain->_check_clean_shutdown()  if !$domain->is_active;
    return $domain;
}

=head2 is_known

Returns if the domain is known in Ravada.

=cut

sub is_known {
    my $self = shift;
    return $self->_select_domain_db(name => $self->name);
}

=head2 start_time

Returns the last time (epoch format in seconds) the
domain was started.

=cut

sub start_time {
    my $self = shift;
    return $self->_data('start_time');
}

sub _select_domain_db {
    my $self = shift;
    my %args = @_;

    _init_connector();

    if (!keys %args) {
        my $id;
        eval { $id = $self->id  };
        if ($id) {
            %args =( id => $id );
        } else {
            %args = ( name => $self->name );
        }
    }

    my $sth = $$CONNECTOR->dbh->prepare(
        "SELECT * FROM domains WHERE ".join(",",map { "$_=?" } sort keys %args )
    );
    $sth->execute(map { $args{$_} } sort keys %args);
    my $row = $sth->fetchrow_hashref;
    $sth->finish;

    $self->{_data} = $row;

    return $row if $row->{id};
}

sub _post_select_domain_db {
    my $self = shift;
    $self->description($self->{_data}->{description})
        if defined $self->{_data}->{description}
};

sub _prepare_base_db {
    my $self = shift;
    my @file_img = @_;

    if (!$self->_select_domain_db) {
        confess "CRITICAL: The data should be already inserted";
#        $self->_insert_db( name => $self->name, id_owner => $self->id_owner );
    }
    my $sth = $$CONNECTOR->dbh->prepare(
        "INSERT INTO file_base_images "
        ." (id_domain , file_base_img, target )"
        ." VALUES(?,?,?)"
    );
    for my $file_img (@file_img) {
        my $target;
        ($file_img, $target) = @$file_img if ref $file_img;
        $sth->execute($self->id, $file_img, $target );
    }
    $sth->finish;

    $sth = $$CONNECTOR->dbh->prepare(
        "UPDATE domains SET is_base=1 "
        ." WHERE id=?");
    $sth->execute($self->id);
    $sth->finish;

    $self->_select_domain_db();
}

sub _set_spice_password {
    my $self = shift;
    my $password = shift;

    my $sth = $$CONNECTOR->dbh->prepare(
       "UPDATE domains set spice_password=?"
       ." WHERE id=?"
    );
    $sth->execute($password, $self->id);
    $sth->finish;

    $self->{_data}->{spice_password} = $password;
}

=head2 spice_password

Returns the password defined for the spice viewers

=cut

sub spice_password {
    my $self = shift;
    return $self->_data('spice_password');
}

=head2 display_file

Returns a file with the display information. Defaults to spice.

=cut

sub display_file($self,$user) {
    return $self->_display_file_spice($user);
}

# taken from isard-vdi thanks to @tuxinthejungle Alberto Larraz
sub _display_file_spice($self,$user) {

    my ($ip,$port) = $self->display($user) =~ m{spice://(\d+\.\d+\.\d+\.\d+):(\d+)};

    die "I can't find ip port in ".$self->display   if !$ip ||!$port;

    my $ret =
        "[virt-viewer]\n"
        ."type=spice\n"
        ."host=$ip\n";
    if ($self->tls) {
        $ret .= "tls-port=%s\n";
    } else {
        $ret .= "port=$port\n";
    }
    $ret .="password=%s\n"  if $self->spice_password();

    $ret .=
        "fullscreen=1\n"
        ."title=".$self->name." - Press SHIFT+F12 to exit\n"
        ."enable-smartcard=0\n"
        ."enable-usb-autoshare=1\n"
        ."delete-this-file=1\n"
        ."usb-filter=-1,-1,-1,-1,0\n";

    $ret .=";" if !$self->tls;
    $ret .= "tls-ciphers=DEFAULT\n"
        .";host-subject=O=".$ip.",CN=?\n";

    $ret .=";"  if !$self->tls;
    $ret .="ca=CA\n"
        ."toggle-fullscreen=shift+f11\n"
        ."release-cursor=shift+f12\n"
        ."secure-attention=ctrl+alt+end\n";
    $ret .=";" if !$self->tls;
    $ret .="secure-channels=main;inputs;cursor;playback;record;display;usbredir;smartcard\n";

    return $ret;
}

sub _insert_db {
    my $self = shift;
    my %field = @_;

    _init_connector();

    for (qw(name id_owner)) {
        confess "Field $_ is mandatory ".Dumper(\%field)
            if !exists $field{$_};
    }

    my ($vm) = ref($self) =~ /.*\:\:(\w+)$/;
    confess "Unknown domain from ".ref($self)   if !$vm;
    $field{vm} = $vm;

    my $query = "INSERT INTO domains "
            ."(" . join(",",sort keys %field )." )"
            ." VALUES (". join(",", map { '?' } keys %field )." ) "
    ;
    my $sth = $$CONNECTOR->dbh->prepare($query);
    eval { $sth->execute( map { $field{$_} } sort keys %field ) };
    if ($@) {
        #warn "$query\n".Dumper(\%field);
        confess $@;
    }
    $sth->finish;

}

=head2 pre_remove

Code to run before removing the domain. It can be implemented in each domain.
It is not expected to run by itself, the remove function calls it before proceeding.

    $domain->pre_remove();  # This isn't likely to be necessary
    $domain->remove();      # Automatically calls the domain pre_remove method

=cut

sub pre_remove { }

sub _pre_remove_domain($self, $user, @) {

    eval { $self->id };
    $self->pre_remove();
    $self->_allow_remove($user);
    $self->pre_remove();
#    warn "remove ".$self->name." 1\n";
}

sub _after_remove_domain {
    my $self = shift;
    my ($user, $cascade) = @_;

    $self->_remove_iptables(user => $user)  if $self->is_known();
    $self->_remove_domain_cascade($user)   if !$cascade;

    if ($self->is_base) {
        $self->_do_remove_base(@_);
        $self->_remove_files_base();
    }
    return if !$self->{_data};
    $self->_remove_base_db();
    $self->_remove_domain_db();
}

# removes domain in other VMs
sub _remove_domain_cascade($self,$user, $cascade = 1) {

    return if !$self->_vm;
    my $sth = $$CONNECTOR->dbh->prepare("SELECT id,name FROM vms WHERE is_active=1");
    my ($id, $name);
    $sth->execute();
    $sth->bind_columns(\($id, $name));
    while ($sth->fetchrow) {
        next if $id == $self->_vm->id;
        my $vm = Ravada::VM->open($id);
        my $domain = $vm->search_domain($self->name) or next;

        $domain->remove($user, $cascade);
    }
}

sub _remove_domain_db {
    my $self = shift;

    return if !$self->is_known();

    $self->_select_domain_db or return;
    my $sth = $$CONNECTOR->dbh->prepare("DELETE FROM domains "
        ." WHERE id=?");
    $sth->execute($self->id);
    $sth->finish;
}

sub _remove_files_base {
    my $self = shift;

    for my $file ( $self->list_files_base ) {
        unlink $file or die "$! $file" if -e $file;
    }
}


sub _remove_id_base {

    my $self = shift;

    my $sth = $$CONNECTOR->dbh->prepare(
        "UPDATE domains set id_base=NULL "
        ." WHERE id=?"
    );
    $sth->execute($self->id);
    $sth->finish;
}

=head2 is_base
Returns true or  false if the domain is a prepared base
=cut

sub is_base {
    my $self = shift;
    my $value = shift;

    $self->_select_domain_db or return 0;

    if (defined $value ) {
        my $sth = $$CONNECTOR->dbh->prepare(
            "UPDATE domains SET is_base=? "
            ." WHERE id=?");
        $sth->execute($value, $self->id );
        $sth->finish;

        return $value;
    }
    my $ret = $self->_data('is_base');
    $ret = 0 if $self->_data('is_base') =~ /n/i;

    return $ret;
};

=head2 is_locked
Shows if the domain has running or pending requests. It could be considered
too as the domain is busy doing something like starting, shutdown or prepare base.
Returns true if locked.
=cut

sub is_locked {
    my $self = shift;

    $self->_init_connector() if !defined $$CONNECTOR;

    my $sth = $$CONNECTOR->dbh->prepare("SELECT id,at_time FROM requests "
        ." WHERE id_domain=? AND status <> 'done'");
    $sth->execute($self->id);
    my ($id, $at_time) = $sth->fetchrow;
    $sth->finish;

    return 0 if $at_time && $at_time - time > 1;
    return ($id or 0);
}

=head2 id_owner
Returns the id of the user that created this domain
=cut

sub id_owner {
    my $self = shift;
    return $self->_data('id_owner',@_);
}

=head2 id_base
Returns the id from the base this domain is based on, if any.
=cut

sub id_base {
    my $self = shift;
    return $self->_data('id_base',@_);
}

=head2 vm
Returns a string with the name of the VM ( Virtual Machine ) this domain was created on
=cut


sub vm {
    my $self = shift;
    return $self->_data('vm');
}

=head2 clones
Returns a list of clones from this virtual machine
    my @clones = $domain->clones
=cut

sub clones {
    my $self = shift;

    _init_connector();

    my $sth = $$CONNECTOR->dbh->prepare("SELECT id, name FROM domains "
            ." WHERE id_base = ? AND (is_base=NULL OR is_base=0)");
    $sth->execute($self->id);
    my @clones;
    while (my $row = $sth->fetchrow_hashref) {
        # TODO: open the domain, now it returns only the id
        push @clones , $row;
    }
    return @clones;
}

=head2 has_clones
Returns the number of clones from this virtual machine
    my $has_clones = $domain->has_clones
=cut

sub has_clones {
    my $self = shift;

    _init_connector();

    return scalar $self->clones;
}


=head2 list_files_base
Returns a list of the filenames of this base-type domain
=cut

sub list_files_base {
    my $self = shift;
    my $with_target = shift;

    return if !$self->is_known();

    my $id;
    eval { $id = $self->id };
    return if $@ && $@ =~ /No DB info/i;
    die $@ if $@;

    my $sth = $$CONNECTOR->dbh->prepare("SELECT file_base_img, target "
        ." FROM file_base_images "
        ." WHERE id_domain=?");
    $sth->execute($self->id);

    my @files;
    while ( my ($img, $target) = $sth->fetchrow) {
        push @files,($img)          if !$with_target;
        push @files,[$img,$target]  if $with_target;
    }
    $sth->finish;
    return @files;
}

=head2 list_files_base_target

Returns a list of the filenames and targets of this base-type domain

=cut

sub list_files_base_target {
    return $_[0]->list_files_base("target");
}

=head2 json
Returns the domain information as json
=cut

sub json {
    my $self = shift;

    my $id = $self->_data('id');
    my $data = $self->{_data};
    $data->{is_active} = $self->is_active;

    return encode_json($data);
}

=head2 can_screenshot
Returns wether this domain can take an screenshot.
=cut

sub can_screenshot {
    return 0;
}

sub _convert_png {
    my $self = shift;
    my ($file_in ,$file_out) = @_;

    my $in = Image::Magick->new();
    my $err = $in->Read($file_in);
    confess $err if $err;

    $in->Scale(width => 250, height => 188);
    $in->Write("png24:$file_out");

    chmod 0755,$file_out or die "$! chmod 0755 $file_out";
}

=head2 remove_base
Makes the domain a regular, non-base virtual machine and removes the base files.
=cut

sub remove_base {
    my $self = shift;
    return $self->_do_remove_base();
}

sub _do_remove_base {
    my $self = shift;
    $self->is_base(0);
    for my $file ($self->list_files_base) {
        next if ! -e $file;
        unlink $file or die "$! unlinking $file";
    }
    $self->storage_refresh()    if $self->storage();
}

sub _pre_remove_base {
    _allow_manage(@_);
    _check_has_clones(@_);
    $_[0]->spinoff_volumes();
}

sub _post_remove_base {
    my $self = shift;
    $self->_remove_base_db(@_);
    $self->_post_remove_base_domain();
    $self->_set_base_vm_db($self->_vm->id,1);
}

sub _pre_shutdown_domain {}

sub _post_remove_base_domain {}

sub _remove_base_db {
    my $self = shift;

    my $sth = $$CONNECTOR->dbh->prepare("DELETE FROM file_base_images "
        ." WHERE id_domain=?");

    $sth->execute($self->{_data}->{id});
    $sth->finish;

}

=head2 clone

Clones a domain

=head3 arguments

=over

=item user => $user : The user that owns the clone

=item name => $name : Name of the new clone

=back

=cut

sub clone {
    my $self = shift;
    my %args = @_;

    my $name = delete $args{name}
        or confess "ERROR: Missing domain cloned name";

    my $user = delete $args{user}
        or confess "ERROR: Missing request user";

    confess "ERROR: Clones can't be created in readonly mode"
        if $self->_vm->readonly();

    return $self->_copy_clone(@_)   if $self->id_base();

    my $request = delete $args{request};
    my $memory = delete $args{memory};

    confess "ERROR: Unknown args ".join(",",sort keys %args)
        if keys %args;

    my $uid = $user->id;

    if ( !$self->is_base() ) {
        $request->status("working","Preparing base")    if $request;
        $self->prepare_base($user)
    }

    my $id_base = $self->id;

    my @args_copy = ();
    push @args_copy, ( memory => $memory )      if $memory;
    push @args_copy, ( request => $request )    if $request;

    my $clone = $self->_vm->create_domain(
        name => $name
        ,id_base => $id_base
        ,id_owner => $uid
        ,vm => $self->vm
        ,_vm => $self->_vm
        ,@args_copy
    );
    return $clone;
}

sub _copy_clone($self, %args) {
    my $name = delete $args{name} or confess "ERROR: Missing name";
    my $user = delete $args{user} or confess "ERROR: Missing user";
    my $memory = delete $args{memory};
    my $request = delete $args{request};

    confess "ERROR: Unknown arguments ".join(",",sort keys %args)
        if keys %args;

    my $base = Ravada::Domain->open($self->id_base);

    my @copy_arg;
    push @copy_arg, ( memory => $memory ) if $memory;

    $request->status("working","Copying domain ".$self->name
        ." to $name")   if $request;

    my $copy = $self->_vm->create_domain(
        name => $name
        ,id_base => $base->id
        ,id_owner => $user->id
        ,_vm => $self->_vm
        ,@copy_arg
    );
    my @volumes = $self->list_volumes_target;
    my @copy_volumes = $copy->list_volumes_target;

    my %volumes = map { $_->[1] => $_->[0] } @volumes;
    my %copy_volumes = map { $_->[1] => $_->[0] } @copy_volumes;
    for my $target (keys %volumes) {
        copy($volumes{$target}, $copy_volumes{$target})
            or die "$! $volumes{$target}, $copy_volumes{$target}"
    }
    return $copy;
}

sub _post_pause {
    my $self = shift;
    my $user = shift;

    $self->_data(status => 'paused');
    $self->_remove_iptables(user => $user);
}

sub _post_hibernate($self, $user) {
    $self->_data(status => 'hibernated');
    $self->_remove_iptables(user => $user);
}

sub _pre_shutdown {
    my $self = shift;
    my %arg = @_;

    my $user = delete $arg{user};
    delete $arg{timeout};
    delete $arg{request};

    confess "Unknown args ".join(",",sort keys %arg)
        if keys %arg;

    $self->_allow_shutdown(@_);

    $self->_pre_shutdown_domain();

    if ($self->is_paused) {
        $self->resume(user => $user);
    }
}

sub _post_shutdown {
    my $self = shift;

    my %arg = @_;
    my $timeout = $arg{timeout};

    $self->_remove_iptables(@_);

    $self->_data(status => 'shutdown')
        if $self->is_known
        && !$self->is_volatile
        && !$self->is_active;

    if ($self->id_base() && !$self->is_removed && !$self->is_volatile && !$self->is_active ) {
        $self->clean_swap_volumes(@_)
    }
    $self->_remove_temporary_machine(@_);
    $self->_remove_iptables(@_);

    if (defined $timeout && !$self->is_removed) {
        if ($timeout<2 && !$self->is_removed && $self->is_active) {
            sleep $timeout;
            $self->_data(status => 'shutdown')    if !$self->is_active;
            return $self->_do_force_shutdown() if !$self->is_removed && $self->is_active;
        }

        my $req = Ravada::Request->force_shutdown_domain(
            id_domain => $self->id
                , uid => $arg{user}->id
                 , at => time+$timeout 
        );
    }
    my $request;
    $request = $arg{request} if exists $arg{request};
    $self->_rsync_volumes_back( $request )
        if !$self->is_local && !$self->is_active && !$self->is_volatile;

}

sub _around_shutdown_now {
    my $orig = shift;
    my $self = shift;
    my $user = shift;

    if ($self->is_active) {
        $self->$orig($user);
    }
    $self->_post_shutdown(user => $user)    if $self->is_known();
}

=head2 can_hybernate

Returns wether a domain supports hybernation

=cut

sub can_hybernate { 0 };

=head2 can_hibernate

Returns wether a domain supports hibernation

=cut

sub can_hibernate {
    my $self = shift;
    return $self->can_hybernate();
};

=head2 add_volume_swap

Adds a swap volume to the virtual machine

Arguments:

    size => $kb
    name => $name (optional)

=cut

sub add_volume_swap {
    my $self = shift;
    my %arg = @_;

    $arg{name} = $self->name if !$arg{name};
    $self->add_volume(%arg, swap => 1);
}

sub _remove_iptables {
    my $self = shift;

    my $args = {@_};

#    confess "Missing user=>\$user" if !$args->{user};

    my $ipt_obj = _obj_iptables();

    my $sth = $$CONNECTOR->dbh->prepare(
        "UPDATE iptables SET time_deleted=?"
        ." WHERE id=?"
    );

    my %rule;
    for my $row ($self->_active_iptables($args->{user})) {
        my ($id, $id_vm, $iptables) = @$row;
        next if !$id_vm;
        push @{$rule{$id_vm}},[ $id, $iptables ];
    }
    for my $id_vm (keys %rule) {
        my $vm = Ravada::VM->open($id_vm);
        for my $entry (@ {$rule{$id_vm}}) {
            my ($id, $iptables) = @$entry;
            if ($vm->is_local) {
                $ipt_obj->delete_ip_rule(@$iptables);
            } else {
                $self->_delete_ip_rule_remote($iptables, $vm);
            }
            $sth->execute(Ravada::Utils::now(), $id);
        }
    }
}

sub _remove_temporary_machine {
    my $self = shift;

    return if !$self->is_volatile;
    my %args = @_;

    return if !$self->is_known();
    return if !$self->is_volatile();

    my $user;
    eval { $user = Ravada::Auth::SQL->search_by_id($self->id_owner) };
    return if !$user;

    my $req= $args{request};
        $req->status(
            "removing"
            ,"Removing domain ".$self->name." after shutdown"
            ." because user "
            .$user->name." is temporary")
                if $req;

        if ($self->is_removed) {
            $self->_after_remove_domain();
        } else {
            $self->remove($user);
        }
}

sub _post_resume {
    return _post_start(@_);
}

sub _post_start {
    my $self = shift;
    my %arg;

    if (scalar @_ % 2) {
        $arg{user} = $_[0];
    } else {
        %arg = @_;
    }

    $self->_data('status','active') if $self->is_active();
    my $sth = $$CONNECTOR->dbh->prepare(
        "UPDATE domains set start_time=? "
        ." WHERE id=?"
    );
    $sth->execute(time, $self->id);
    $sth->finish;

    $self->_add_iptable(@_);
    $self->_update_id_vm();

    if ($self->run_timeout) {
        my $req = Ravada::Request->shutdown_domain(
            id_domain => $self->id
                , uid => $arg{user}->id
                 , at => time+$self->run_timeout
                 , timeout => 59
        );

    }
    $self->get_info();
}

sub _update_id_vm($self) {
    my $sth = $$CONNECTOR->dbh->prepare(
        "UPDATE domains set id_vm=? where id = ?"
    );
    $sth->execute($self->_vm->id, $self->id);
    $sth->finish;

    $self->{_data}->{id_vm} = $self->_vm->id;
}

sub _add_iptable {
    my $self = shift;
    return if scalar @_ % 2;
    my %args = @_;

    my $remote_ip = $args{remote_ip} or return;

    my $user = $args{user};
    my $uid = $user->id;

    my $display = $self->display($user);
    my ($local_ip, $local_port) = $display =~ m{\w+://(.*):(\d+)};

    $self->_open_port($user, $remote_ip, $local_ip, $local_port);
    $self->_close_port($user, '0.0.0.0', $local_ip, $local_port);

}

sub _delete_ip_rule_remote($self, $iptables, $vm = $self->_vm) {

    $self->_load_rex();

    my ($s, $d, $filter, $chain, $jump, $extra) = @$iptables;
    lock_hash %$extra;

    $s .= "/32" if defined $s && $s !~ m{/};
    $d .= "/32" if defined $d && $d !~ m{/};

    my $iptables_list = $self->_vm->iptables_list();

    my $count = 0;
    for my $line (@{$iptables_list->{$filter}}) {
        my %args = @$line;
        next if $args{A} ne $chain;
        $count++;
        if(exists $args{j} && defined $jump         && $args{j} eq $jump
           && exists $args{s} && defined $s && $args{s} eq $s
           && exists $args{d} && defined $d && $args{d} eq $d
           && exists $args{dport} && exists $extra->{d_port}
           && $args{dport} eq $extra->{d_port}) {

           $self->_vm->run_command("iptables -t $filter -D $chain $count");
           $count--;
        }

    }

}
sub _open_port($self, $user, $remote_ip, $local_ip, $local_port, $jump = 'ACCEPT') {
    confess "local port undefined " if !$local_port;

    $self->_vm->create_iptables_chain($IPTABLES_CHAIN);

    my @iptables_arg = ($remote_ip
                        ,$local_ip, 'filter', $IPTABLES_CHAIN, $jump,
                        ,{'protocol' => 'tcp', 's_port' => 0, 'd_port' => $local_port});

    $self->_vm->iptables(
                A => $IPTABLES_CHAIN
                ,m => 'tcp'
                ,p => 'tcp'
                ,s => $remote_ip
                ,d => $local_ip
                ,dport => $local_port
                ,j => $jump
    );

    $self->_log_iptable(iptables => \@iptables_arg, user => $user, remote_ip => $remote_ip);

}

sub _close_port($self, $user, $remote_ip, $local_ip, $local_port) {
    $self->_open_port($user, $remote_ip, $local_ip, $local_port,'DROP');
}

=head2 open_iptables

Open iptables for a remote client

=over

=item user

=item  remote_ip

=back

=cut

sub open_iptables {
    my $self = shift;

    my %args = @_;
    my $user = Ravada::Auth::SQL->search_by_id($args{uid});
    $args{user} = $user;
    delete $args{uid};
    $self->_add_iptable(%args);
}

sub _obj_iptables {

	my %opts = (
    	'use_ipv6' => 0,         # can set to 1 to force ip6tables usage
	    'ipt_rules_file' => '',  # optional file path from
	                             # which to read iptables rules
	    'iptout'   => '/tmp/iptables.out',
	    'ipterr'   => '/tmp/iptables.err',
	    'debug'    => 0,
	    'verbose'  => 0,

	    ### advanced options
	    'ipt_alarm' => 5,  ### max seconds to wait for iptables execution.
	    'ipt_exec_style' => 'waitpid',  ### can be 'waitpid',
	                                    ### 'system', or 'popen'.
	    'ipt_exec_sleep' => 0, ### add in time delay between execution of
	                           ### iptables commands (default is 0).
	);

	my $ipt_obj = IPTables::ChainMgr->new(%opts)
    	or die "[*] Could not acquire IPTables::ChainMgr object";

	my $rv = 0;
	my $out_ar = [];
	my $errs_ar = [];

	#check_chain_exists
	($rv, $out_ar, $errs_ar) = $ipt_obj->chain_exists('filter', $IPTABLES_CHAIN);
    if (!$rv) {
		$ipt_obj->create_chain('filter', $IPTABLES_CHAIN);
        $ipt_obj->add_jump_rule('filter','INPUT', 1, $IPTABLES_CHAIN);
	}
	# set the policy on the FORWARD table to DROP
#    $ipt_obj->set_chain_policy('filter', 'FORWARD', 'DROP');

    return $ipt_obj;
}

sub _log_iptable {
    my $self = shift;
    if (scalar(@_) %2 ) {
        carp "Odd number ".Dumper(\@_);
        return;
    }
    my %args = @_;

    my $remote_ip = delete $args{remote_ip} or confess "ERROR: remote_ip required";
    my $iptables  = delete $args{iptables}  or confess "ERROR: iptables required";
    my $user = delete $args{user};
    my $uid  = delete $args{uid};

    confess "ERROR: Unexpected arguments ".Dumper(\%args) if keys %args;
    confess "ERROR: Choose wether uid or user "
        if $user && $uid;
    confess "ERROR: Supply user or uid" if !defined $user && !defined $uid;

    lock_hash(%args);

    $uid = $user->id if !$uid;


    my $sth = $$CONNECTOR->dbh->prepare(
        "INSERT INTO iptables "
        ."(id_domain, id_user, remote_ip, time_req, iptables, id_vm)"
        ."VALUES(?, ?, ?, ?, ?, ?)"
    );
    $sth->execute($self->id, $uid, $remote_ip, Ravada::Utils::now()
        ,encode_json($iptables), $self->_vm->id);
    $sth->finish;

}

sub _active_iptables($self, $user=undef) {

    my @sql_args = ($self->id);
    my $sql
        ="SELECT id, id_vm, iptables FROM iptables "
        ." WHERE "
        ."    id_domain=? ";
    if ($user) {
        $sql .= "    AND id_user=? ";
        push @sql_args,($user->id);
    }
    $sql .=
         "    AND time_deleted IS NULL"
        ." ORDER BY time_req DESC ";

    my $sth = $$CONNECTOR->dbh->prepare($sql);
    $sth->execute(@sql_args);

    my @iptables;
    while (my ( $id, $id_vm, $iptables ) = $sth->fetchrow) {
        push @iptables, [ $id, $id_vm, decode_json($iptables)];
    }
    return @iptables;
}

sub _check_duplicate_domain_name {
    my $self = shift;
# TODO
#   check name not in current domain in db
#   check name not in other VM domain
    $self->id();
}

sub _rename_domain_db {
    my $self = shift;
    my %args = @_;

    my $new_name = $args{name} or confess "Missing new name";

    my $sth = $$CONNECTOR->dbh->prepare("UPDATE domains set name=?"
                ." WHERE id=?");
    $sth->execute($new_name, $self->id);
    $sth->finish;
}

=head2 is_public

Sets or get the domain public

    $domain->is_public(1);

    if ($domain->is_public()) {
        ...
    }

=cut

sub is_public {
    my $self = shift;
    my $value = shift;

    _init_connector();
    if (defined $value) {
        my $sth = $$CONNECTOR->dbh->prepare("UPDATE domains set is_public=?"
                ." WHERE id=?");
        $sth->execute($value, $self->id);
        $sth->finish;
        $self->{_data}->{is_public} = $value;
    }
    return $self->_data('is_public');
}


=head2 run_timeout

Sets or get the domain run timeout. When it expires it is shut down.

    $domain->run_timeout(60 * 60); # 60 minutes

=cut

sub run_timeout {
    my $self = shift;

    return $self->_data('run_timeout',@_);
}

#sub _set_data($self, $field, $value=undef) {
#    if (defined $value) {
#        warn "\t".$self->id." ".$self->name." $field = $value\n";
#        my $sth = $$CONNECTOR->dbh->prepare("UPDATE domains set $field=?"
#                ." WHERE id=?");
#        $sth->execute($value, $self->id);
#        $sth->finish;
#        $self->{_data}->{$field} = $value;
#
#        $self->_propagate_data($field,$value) if $PROPAGATE_FIELD{$field};
#    }
#    return $self->_data($field);
#}
sub _set_data($self, $field, $value) {
    return $self->_data($field, $value);
}

sub _propagate_data($self, $field, $value) {
    my $sth = $$CONNECTOR->dbh->prepare("UPDATE domains set $field=?"
                ." WHERE id_base=?");
    $sth->execute($value, $self->id);
    $sth->finish;
}

=head2 clean_swap_volumes

Check if the domain has swap volumes defined, and clean them

    $domain->clean_swap_volumes();

=cut

sub clean_swap_volumes {
    my $self = shift;
    for my $file ( $self->list_volumes) {
        $self->clean_disk($file)
            if $file =~ /\.SWAP\.\w+$/;
    }
}


sub _pre_rename {
    my $self = shift;

    my %args = @_;
    my $name = $args{name};
    my $user = $args{user};

    $self->_check_duplicate_domain_name(@_);

    $self->shutdown(user => $user)  if $self->is_active;
}

sub _post_rename {
    my $self = shift;
    my %args = @_;

    $self->_rename_domain_db(@_);
}

 sub _post_screenshot {
     my $self = shift;
     my ($filename) = @_;

     return if !defined $filename;

     my $sth = $$CONNECTOR->dbh->prepare(
         "UPDATE domains set file_screenshot=? "
         ." WHERE id=?"
     );
     $sth->execute($filename, $self->id);
     $sth->finish;
 }

=head2 drivers

List the drivers available for a domain. It may filter for a given type.

    my @drivers = $domain->drivers();
    my @video_drivers = $domain->drivers('video');

=cut

sub drivers {
    my $self = shift;
    my $name = shift;
    my $type = shift;
    $type = $self->type         if $self && !$type;
    $type = $self->_vm->type    if $self && !$type;

    _init_connector();

    my $query = "SELECT id from domain_drivers_types ";

    my @sql_args = ();

    my @where;
    if ($name) {
        push @where,("name=?");
        push @sql_args,($name);
    }
    if ($type) {
        my $type2 = $type;
        if ($type =~ /qemu/) {
            $type2 = 'KVM';
        } elsif ($type =~ /KVM/) {
            $type2 = 'qemu';
        }
        push @where, ("( vm=? OR vm=?)");
        push @sql_args, ($type,$type2);
    }
    $query .= "WHERE ".join(" AND ",@where) if @where;
    my $sth = $$CONNECTOR->dbh->prepare($query);

    $sth->execute(@sql_args);

    my @drivers;
    while ( my ($id) = $sth->fetchrow) {
        push @drivers,Ravada::Domain::Driver->new(id => $id, domain => $self);
    }
    return $drivers[0] if !wantarray && $name && scalar@drivers< 2;
    return @drivers;
}

=head2 set_driver_id

Sets the driver of a domain given it id. The id must be one from
the table domain_drivers_options

    $domain->set_driver_id($id_driver);

=cut

sub set_driver_id {
    my $self = shift;
    my $id = shift;

    my $sth = $$CONNECTOR->dbh->prepare(
        "SELECT d.name,o.value "
        ." FROM domain_drivers_types d, domain_drivers_options o"
        ." WHERE d.id=o.id_driver_type "
        ."    AND o.id=?"
    );
    $sth->execute($id);

    my ($type, $value) = $sth->fetchrow;
    confess "Unknown driver option $id" if !$type || !$value;

    $self->set_driver($type => $value);
    $sth->finish;
}

sub remote_ip {
    my $self = shift;

    my $sth = $$CONNECTOR->dbh->prepare(
        "SELECT remote_ip, iptables FROM iptables "
        ." WHERE "
        ."    id_domain=?"
        ."    AND time_deleted IS NULL"
        ." ORDER BY time_req DESC "
    );
    $sth->execute($self->id);
    while ( my ($remote_ip, $iptables_json ) = $sth->fetchrow() ) {
        my $iptables = decode_json($iptables_json);
        next if $iptables->[4] ne 'ACCEPT';
        # TODO check multiple IPs
        return $remote_ip;
    }
    $sth->finish;
    return;

}

=head2 last_vm

Returns the last virtual machine manager on which this domain was
launched.

    my $vm = $domain->last_vm();

=cut

sub last_vm {
    my $self = shift;

    my $id_vm = $self->_data('id_vm');

    return if !$id_vm;

    return Ravada::VM->open($id_vm);
}

=head2 list_requests

Returns a list of pending requests from the domain. It won't show those requests
scheduled for later.

=cut

sub list_requests {
    my $self = shift;
    my $all = shift;

    my $sth = $$CONNECTOR->dbh->prepare(
        "SELECT * FROM requests WHERE id_domain = ? AND status <> 'done'"
    );
    $sth->execute($self->id);
    my @list;
    while ( my $req_data =  $sth->fetchrow_hashref ) {
        next if !$all && $req_data->{at_time} && $req_data->{at_time} - time > 1;
        push @list,($req_data);
    }
    $sth->finish;
    return scalar @list if !wantarray;
    return map { Ravada::Request->open($_->{id}) } @list;
}

=head2 list_all_requests

Returns a list of pending requests from the domain including those scheduled for later

=cut

sub list_all_requests {
    return list_requests(@_,'all');
}

=head2 get_driver

Returns the driver from a domain

Argument: name of the device [ optional ]
Returns all the drivers if not passwed

    my $driver = $domain->get_driver('video');

=cut

sub get_driver {}

sub _dbh {
    my $self = shift;
    _init_connector() if !$CONNECTOR || !$$CONNECTOR;
    return $$CONNECTOR->dbh;
}

=head2 set_option

Sets a domain option:

=over

=item * description

=item * run_timeout

=back


    $domain->set_option(description => 'Virtual Machine for ...');

=cut

sub set_option($self, $option, $value) {
    if ($option eq 'description') {
        warn "$option -> $value\n";
        $self->description($value);
    } elsif ($option eq 'run_timeout') {
        $self->run_timeout($value);
    } else {
        confess "ERROR: Unknown option '$option'";
    }
}

=head2 type

Returns the virtual machine type as a string.

=cut

sub type {
    my $self = shift;
    return $self->_data('vm');
}

=head2 rsync

Synchronizes the volume data to a remote node.

Argument: Ravada::VM

=cut

sub rsync($self, $node=$self->_vm, $request=undef) {
    $request->status("working") if $request;
    # TODO check if domain is running on remote , then return
    my $ssh = $node->_connect_ssh();
    die "No Connection to ".$node->host if !$ssh;
#    This does nothing and doesn't fail
#
#    for my $file ( $self->list_volumes()) {
#        warn "sending $file\n";
#        my $ret = $ssh2->scp_put($file, $file);
#        warn Dumper($ret);
#        die $ssh2->die_with_error   if !$ret;
#        warn $ssh2->error   if $ssh2->error;
#    }


# TODO: waiting for latest SFTP Foreign in Ubuntu debian package
#    my $sftp = Net::SFTP::Foreign->new(
#        ssh2 => $ssh2,
#        ,backend => 'Net_SSH2'
#    );
#    $sftp->die_on_error("Unable to establish SFTP connection");
    my @files_base;
    if ($self->is_base) {
        push @files_base,($self->list_files_base);
    }
    my $rsync = File::Rsync->new(update => 1);
    for my $file ( $self->list_volumes(), @files_base) {
        $request->status("syncing","Tranferring $file to ".$node->host)
            if $request;
        $rsync->exec(src => $file, dest => 'root@'.$node->host.":".$file );
    }
    if ($rsync->err) {
        $request->status("done",join(" ",@{$rsync->err}))   if $request;
    }
    $node->refresh_storage_pools();
    $self->_set_base_vm_db($node->id,1) if $self->is_base;
}

sub _rsync_volumes_back($self, $request=undef) {
    my $rsync = File::Rsync->new(update => 1);
    for my $file ( $self->list_volumes() ) {
        $rsync->exec(src => 'root@'.$self->_vm->host.":".$file ,dest => $file );
        if ( $rsync->err ) {
            $request->status("done",join(" ",@{$rsync->err}))   if $request;
            last;
        }
    }
    $self->_vm->refresh_storage_pools();
}

sub _pre_migrate($self, $node) {

    $self->_check_equal_storage_pools($node);

    return if !$self->id_base;
    my $base = Ravada::Domain->open($self->id_base);

    die "ERROR: Base ".$base->name." files not migrated to ".$node->name
        if !$base->base_in_vm($node->id);

    for my $file ( $base->list_files_base ) {

        my ($name) = $file =~ m{.*/(.*)};

        my $vol_path = $node->search_volume_path($name);
        die "ERROR: $file not found in ".$node->host
            if !$vol_path;

        die "ERROR: $name found at $vol_path instead $file"
            if $vol_path ne $file;
    }

    $self->_set_base_vm_db($node->id,0);
}

sub _post_migrate($self, $node) {
    $self->_set_base_vm_db($node->id,1) if $self->is_base;
    $self->_vm($node);
    $self->_update_id_vm();

    # TODO: update db instead set this value
    $self->{_migrated} = 1;

}

sub _set_base_vm_db($self, $id_vm, $value) {
    my $is_base = $self->is_base && $self->base_in_vm($id_vm);
    if (!defined $is_base) {
        my $sth = $$CONNECTOR->dbh->prepare(
            "INSERT INTO bases_vm (id_domain, id_vm, enabled) "
            ." VALUES(?, ?, ?)"
        );
        $sth->execute($self->id, $id_vm, $value);
        $sth->finish;
    } else {
        my $sth = $$CONNECTOR->dbh->prepare(
            "UPDATE bases_vm SET enabled=?"
            ." WHERE id_domain=? AND id_vm=?"
        );
        $sth->execute($value, $self->id, $id_vm);
        $sth->finish;
    }
}

=head2 set_base_vm

    Prepares or removes a base in a virtual manager.

    $domain->set_base_vm(
        id_vm => $id_vm         # you can pass the id_vm
          ,vm => $vm            #    or the vm
        ,user => $user
       ,value => $value  # if it is 0, it removes the base
     ,request => $req
    );

=cut

sub set_base_vm($self, %args) {

    my $id_vm = delete $args{id_vm};
    my $value = delete $args{value};
    my $user  = delete $args{user};
    my $vm    = delete $args{vm};
    my $request = delete $args{request};

    confess "ERROR: Unknown arguments, valid are id_vm, value, user and vm "
        .Dumper(\%args) if keys %args;

    confess "ERROR: Supply either id_vm or vm argument"
        if (!$id_vm && !$vm) || ($id_vm && $vm);

    confess "ERROR: user required"  if !$user;

    $request->status("working") if $request;
    $vm = Ravada::VM->open($id_vm)  if !$vm;

    $value = 1 if !defined $value;

    if ($vm->is_local) {
        $self->_set_vm($vm,1);
        if (!$value) {
            $request->status("working","Removing base")     if $request;
            for my $vm_node ( $self->list_vms ) {
                $self->set_base_vm(vm => $vm_node, user => $user, value => 0
                    , request => $request) if !$vm_node->is_local;
            }
            $self->_set_base_vm_db($vm->id, $value);
            $self->remove_base($user);
        } else {
            $self->prepare_base($user);
            $request->status("working","Preparing base")    if $request;
        }
    } elsif ($value) {
        $request->status("working", "Syncing base volumes to ".$vm->host)
            if $request;
        $self->rsync($vm, $request);
    }
    return $self->_set_base_vm_db($vm->id, $value);
}

=head2 remove_base_vm

Removes a base in a Virtual Machine Manager node.

  $domain->remove_base_vm($vm, $user);

=cut

sub remove_base_vm($self, %args) {
    my $user = delete $args{user};
    my $vm = delete $args{vm};
    confess "ERROR: Unknown arguments ".join(',',sort keys %args).", valid are user and vm."
        if keys %args;

    return $self->set_base_vm(vm => $vm, user => $user, value => 0);
}

sub file_screenshot($self) {
    return $self->_data('file_screenshot');
}

sub _pre_clone($self,%args) {
    my $name = delete $args{name};
    my $user = delete $args{user};
    my $memory = delete $args{memory};
    delete $args{request};

    confess "ERROR: Missing clone name "    if !$name;
    confess "ERROR: Invalid name '$name'"   if $name !~ /^[a-z0-9_-]+$/i;

    confess "ERROR: Missing user owner of new domain"   if !$user;

    confess "ERROR: Unknown arguments ".join(",",sort keys %args)   if keys %args;
}

=head2 list_vms

Returns a list for virtual machine managers where this domain is base

=cut

sub list_vms($self) {
    confess "Domain is not base" if !$self->is_base;

    my $sth = $$CONNECTOR->dbh->prepare("SELECT id_vm FROM bases_vm WHERE id_domain=?");
    $sth->execute($self->id);
    my @vms;
    while (my $id_vm = $sth->fetchrow) {
        push @vms,(Ravada::VM->open($id_vm));
    }
    return @vms;
}

=head2 base_in_vm

Returns if this domain has a base prepared in this virtual manager

    if ($domain->base_in_vm($id_vm)) { ...

=cut

sub base_in_vm($self,$id_vm) {

    confess "ERROR: id_vm must be a number, it is '$id_vm'"
        if $id_vm !~ /^\d+$/;

    confess "ERROR: Domain ".$self->name." is not a base"
        if !$self->is_base;

    confess "Undefined id_vm " if !defined $id_vm;
    my $sth = $$CONNECTOR->dbh->prepare(
        "SELECT enabled FROM bases_vm "
        ." WHERE id_domain = ? AND id_vm = ?"
    );
    $sth->execute($self->id, $id_vm);
    my ( $enabled ) = $sth->fetchrow;
    $sth->finish;
#    return 1 if !defined $enabled
#        && $id_vm == $self->_vm->id && $self->_vm->host eq 'localhost';
    return $enabled;
}

=head2 is_local

Returns wether this domain is in the local host

=cut

sub is_local($self) {
    return $self->_vm->is_local();
}

=head2 is_volatile

Returns if the domain is volatile, so it will disappear on shutdown

=cut

sub is_volatile($self, $value=undef) {
    return $self->_data('is_volatile', $value);
}
1;
