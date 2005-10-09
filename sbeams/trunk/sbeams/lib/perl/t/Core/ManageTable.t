#!/usr/local/bin/perl -w

use strict;
use Test::More tests => 21;
#use lib '/net/dblocal/www/html/devDC/sbeams/lib/perl';
use lib qw ( ../.. );

my ( $sbeams, $q );

BEGIN {
use_ok( 'CGI' );
use_ok( 'SBEAMS::Connection' );
use_ok( 'SBEAMS::Connection::Settings' );
use_ok( 'SBEAMS::Connection::Tables' );
use_ok( 'SBEAMS::Connection::TableInfo' );
use_ok( 'HTTP::Request::Common' );
use_ok( 'LWP::UserAgent' );
#use_ok( 'Symbol' );
$q = new CGI;
setup_test();

sub setup_test {
# Insert user of known permissions
my $ua = LWP::UserAgent->new();
my $url = 'http://db.systemsbiology.net/devDC/sbeams/cgi/ManageTable.cgi';
my %form = ( username => 'dcampbel',
             password => 'DaveyJonesLocker',
             group_id => 45,
             first_name => 'Lester',
             location => 'asdf',
             apply_action_hidden => '',
             organization_id => 40,
             record_status => 'N',
             job_title => 'Lackey',
             contact_id => 0,
             lab_id => 13,
             apply_action => 'INSERT',
             last_name => 'Fester',
             contact_type_id => 5,
             supervisor_contact_id => 92,
             middle_name => 'T',
             department_id => 8,
             is_at_local_facility => 'Y',
             action => 'INSERT',
             TABLE_NAME => 'contact'
           );
my $response = $ua->post( $url, \%form );
#print "\t" . $response->content() . "\n";

# Add login for this user
print "Before the script, there was... BEGIN\n";
} # End setup test
} # End BEGIN
END {
breakdown();
}

sub breakdown {
print "After the script, there was... END\n";
}

ok( sbeams_connect(), 'sbeams connection' );
ok( sbeams_authenticate(), 'sbeams authenticate' );
ok( check_authentication_info(), 'sbeams login info' );
ok( sbeams_get_best_permission(), 'sbeams permissions' );
ok( sbeams_get_best_permission_withID(), 'sbeams permissions with ID' );
ok( sbeams_get_best_permission_with_contact(), 'sbeams permissions with contact' );
ok( sbeams_getTablePermissions(), 'sbeams Table permissions with contact' );
ok( sbeams_slamgroup(), 'sbeams slam to group developer' );
ok( sbeams_getTablePermissions(), 'sbeams Table permissions post group slammage' );
ok( sbeams_get_best_permission(), 'sbeams permissions post group slammage' );
ok( sbeams_slamproject(), 'sbeams slam to project youngah' );
ok( sbeams_getTablePermissions(), 'sbeams Table permissions post project slammage' );
ok( sbeams_get_best_permission(), 'sbeams permissions post project slammage' );
ok( check_authentication_info(), 'sbeams login info' );

sub sbeams_slamgroup {
$sbeams->setCurrent_work_group ( set_to_work_group => 'developer' );

}

sub sbeams_slamproject {
$sbeams->setCurrent_project_id (  set_to_project_id => 229 );
}

sub sbeams_connect {
$sbeams = new SBEAMS::Connection;
}

sub sbeams_authenticate {
$sbeams->Authenticate();
}

sub check_authentication_info {
print STDERR "\tCurrent contact ID is " . $sbeams->getCurrent_contact_id() . "\n";
print STDERR "\tCurrent username ID is " . $sbeams->getCurrent_username() . "\n";
print STDERR "\tCurrent work group ID is " . $sbeams->getCurrent_work_group_id() . "\n";
print STDERR "\tCurrent work group is " . $sbeams->getCurrent_work_group_name() . "\n";
print STDERR "\tCurrent project is " . $sbeams->getCurrent_project_name() . "\n";
print STDERR "\tCurrent project ID is " . $sbeams->getCurrent_project_id() . "\n";
1;
}

sub sbeams_get_best_permission {
my $p = $sbeams->get_best_permission();
print "\tBest permission is $p\n";
return $p;
}

sub sbeams_get_best_permission_withID {
my $p = $sbeams->get_best_permission( project_id => 122 );
print "\tBest permission is with proj 122 is $p\n";
return $p;
}

sub sbeams_get_best_permission_with_contact {
my $p = $sbeams->get_best_permission( contact_id => 108 );
print "\tBest permission is with contact_id 108 is $p\n";
return $p;
}

sub sbeams_getTablePermissions {
my $p = $sbeams->calculateTablePermission( table_name => 'project',
                                      dbtable => '$TB_PROJECT',
                                     contact_id => $sbeams->getCurrent_contact_id(),
                                     work_group_id => $sbeams->getCurrent_work_group_id()
 );
print "\tTable permission for sbeams.dbo.project is $p\n ";
}


