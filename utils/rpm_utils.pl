#!/usr/bin/perl
#-----------------------------------------------------------------------bl-
#--------------------------------------------------------------------------
# 
# LosF - a Linux operating system Framework for HPC clusters
#
# Copyright (C) 2007,2008,2009,2010,2011,2012 Karl W. Schulz
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the Version 2 GNU General
# Public License as published by the Free Software Foundation.
#
# These programs are distributed in the hope that they will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc. 51 Franklin Street, Fifth Floor, 
# Boston, MA  02110-1301  USA
#
#-----------------------------------------------------------------------el-
#
# Utility Functions
#
# $Id$
#--------------------------------------------------------------------------

use OSF_paths;

use lib "$osf_log4perl_dir";
use lib "$osf_rpm2_dir";
use lib "$osf_rpm2_arch_dir";

use rpm_topdir;
use Sys::Syslog;  
use Digest::MD5;
use Env qw(SRC_DIR MODE);
use Term::ANSIColor;

# --------------------------------------------------------
# verify_rpms (rpms)
# 
# Checks to see if input list of Distro rpms versions are
# installed; if not, installs desires packages.
# --------------------------------------------------------

sub verify_rpms {
    begin_routine();

    my @rpm_list        = @_;
    my @rpms_to_install = ();
    my $num_rpms        = @rpm_list;

    if($num_rpms < 1) { return; }

    INFO("   --> Verifying desired OS RPMs are installed ($num_rpms total)...\n");
    foreach $rpm (@rpm_list) {
	DEBUG("   --> Checking $rpm\n");

	# Installing from path provided by user on command-line?

	my $filename = "";
	my $arch     = rpm_arch_from_filename($rpm);

	if ( "$MODE" eq "PXE" ) {
	    $filename = "$SRC_DIR/$arch/$rpm.rpm";
	} else {
	    $filename = "$rpm_topdir/$arch/$rpm.rpm";
	}

	if ( ! -s "$filename" ) {
	    MYERROR("Unable to locate local OS rpm-> $filename\n");
	}

	# return array format = (name,version,release,arch)

	my @desired_rpm   = rpm_version_from_file($filename);
	my @installed_rpm = is_rpm_installed     ($rpm,$arch);

	if( @installed_rpm eq 0 ) {

	    INFO("   --> $desired_rpm[0] is not installed - registering for add...\n");
	    push(@rpms_to_install,$filename);
	} elsif( "$desired_rpm[1]-$desired_rpm[2]" ne "$installed_rpm[1]-$installed_rpm[2]") {
	    INFO("   --> version mismatch - registering for update...\n");
	    push(@rpms_to_install,$filename);
	} else {
	    DEBUG("   --> $desired_rpm[0] is already installed\n");
	}

    }

    # Do the transactions with gool ol' rpm command line (cuz perl interface sucks).

    if( @rpms_to_install eq 0 ) {
	print "   --> "; 
	print color 'green';
	print "OK";
	print color 'reset';
	print ": OS packages in sync ($num_rpms rpms checked)\n";
#	INFO("   --> OK: OS packages in sync ($num_rpms rpms checked)\n");
	return;
    }

    # This is for OS packages, for which there can be only 1 version
    # installed; hence we always upgrade

    my $cmd = "rpm -Uvh "."@rpms_to_install";
    
    #print "cmd = $cmd\n";
    system($cmd);

    my $ret = $?;

    if ( $ret != 0 ) {
	MYERROR("Unable to install OS package RPMs (status = $ret)\n");
    }

    end_routine();
}

# --------------------------------------------------------
# verify_custom_rpms (rpms)
# 
# Checks to see if input list of Custom rpms versions are
# installed; if not, installs desires packages with 
# user specified options.
# --------------------------------------------------------

sub verify_custom_rpms {
    begin_routine();

    my $appliance       = shift;
    my @rpm_list        = @_;
    my %rpms_to_install = ();
    my $num_rpms        = @rpm_list;


    if($num_rpms < 1) { return; }

    INFO("   --> Verifying desired Custom RPMs are installed ($num_rpms total)...\n");

    foreach $rpm (@rpm_list) {

	my @rpm_array  = split(/\s+/,$rpm);

	# Cull rpm install options for this package

	my $md5_desired    = $rpm_array[1];  # <- required option for all custom packages (all others are optional)
	my $num_options    = @rpm_array;

	my $rpm_options    = "";
	my $install_method = "--upgrade ";   # we default to upgrade, may be overridden by parsing options below

	for(my $count = 2; $count < $num_options; $count++) {
	    $rpm_options = $rpm_options . validate_rpm_option($rpm_array[$count]);
	}

	$rpm_options = $install_method . $rpm_options;
	
	# We always use --nosignature as well since we frequently
	# don't import keys to computes; include --hash for visual feedback

	$rpm_options = $rpm_options . "--nosignature --hash -v";

	DEBUG("   --> rpm_options = $rpm_options\n");
	DEBUG("   --> Checking $rpm_array[0]\n");


	# Installing from path provided by user on command-line?

	my $filename = "";
	my $arch     = rpm_arch_from_filename($rpm_array[0]);

	if ( "$MODE" eq "PXE" ) {
	    $filename = "$SRC_DIR/$arch/$rpm_array[0].rpm";
	} else {
	    $filename = "$rpm_topdir/$arch/$rpm_array[0].rpm";
	}

	if ( ! -s "$filename" ) {
	    MYERROR("Unable to locate local Custom rpm-> $filename\n");
	}

	my @desired_rpm   = rpm_version_from_file($filename);
#	my @installed_rpm = is_rpm_installed     ($rpm_array[0],$arch);
	my @installed_rpm = is_rpm_installed     ("$desired_rpm[0]-$desired_rpm[1]",$arch);

	# Decide if we need to install. Note that we build up arrays
	# of rpms to install on a per-rpm-option-combination basis.
	# This is to allow for multiple rpms to be installed, but it
	# is conceivable that some of the rpms which need to be
	# installed have different options specified. This uses a perl
	# array of hashes, so the syntax is slightly gnarly.

	if( @installed_rpm eq 0 ) {
	    verify_expected_md5sum($filename,$md5_desired);
	    INFO("   --> $desired_rpm[0] is not installed - registering for add...\n");
	    SYSLOG("Registering previously uninstalled $desired_rpm[0] for update");
	    push(@{$rpms_to_install{$rpm_options}},$filename);
	} elsif( "$desired_rpm[1]-$desired_rpm[2]" ne "$installed_rpm[1]-$installed_rpm[2]") {
	    verify_expected_md5sum($filename,$md5_desired);
	    INFO("   --> version mismatch - registering for update...\n");
	    SYSLOG("Registering locally installed $desired_rpm[0] for update");
	    push(@{$rpms_to_install{$rpm_options}},$filename);
	} else {
	    DEBUG("   --> $desired_rpm[0] is already installed\n");
	}
    }

    # Do we have rpms to install

    my $count = 0;
    foreach my $options (keys %rpms_to_install) {
	foreach(@{$rpms_to_install{$options}}) {
	    $count++;
	}
    }

    if( $count == 0 ) {
	print "   --> "; 
	print color 'green';
	print "OK";
	print color 'reset';
	print ": Custom packages in sync for $appliance: $num_rpms rpm(s) checked\n";
	return;
    } else {
	print "   --> ";
	print color 'red';
	print "FAILED";
	print color 'reset';
	print ": A total of $count custom rpm(s) need updating for $appliance\n";
    }

    # Do the transactions with gool ol' rpm command line (cuz perl interface sucks).

    foreach my $options (keys %rpms_to_install) {

	my $local_count = @{$rpms_to_install{$options}};
	INFO("   --> Using rpm_options = $options (number of rpms = $local_count)\n");
	SYSLOG("Issuing transactions for $local_count rpm(s) ($options)");

	my $cmd = "rpm $options "."@{$rpms_to_install{$options}}";
    
	system($cmd);

	my $ret = $?;

	if ( $ret != 0 ) {
	    SYSLOG("** Local RPM update unsuccessful");
	    MYERROR("Unable to install Custom RPMs (status = $ret)\n");

	} else {
	    SYSLOG("RPM install(s) successful");
	}

    }

    end_routine();
}

# --------------------------------------------------------
# is_rpm_installed (packagename)
# 
# Checks to see if packagename is installed and returns
# list of matching packages if it is.
# --------------------------------------------------------

sub is_rpm_installed {
    begin_routine();

    my $packagename   = shift;
    my @matching_rpms = ();
    my @empty_list    = ();

    DEBUG("   --> Checking if $packagename RPM is installed locally\n");

    @matching_rpms  = 
	split(' ',`rpm -q --queryformat '%{NAME} %{VERSION} %{RELEASE} %{ARCH}\n' $packagename`);
 
    if( $? != 0) {
	@matching_rpms = @empty_list;
#	return(@empty_list);
    }

    end_routine();

#    print "matching rpms = @matching_rpms\n";
    return(@matching_rpms);
}

# --------------------------------------------------------
# rpm_version_from_file()
# 
# Queries RPM versionioning info from existing RPM
# 
# Return: (name,version,release,arch)
# --------------------------------------------------------

sub rpm_version_from_file {
    begin_routine();

    my $filename = shift;
    my @rpm_info = ();

    DEBUG("   --> Querying RPM file $filename\n");

    if ( ! -e $filename ) { MYERROR("Unable to query rpm file $filename") };

    @rpm_info = split(' ',`rpm --nosignature -qp --queryformat '%{NAME} %{VERSION} %{RELEASE} %{ARCH}\n' $filename`);
    
#    print "name    = $rpm_info[0]\n";
#    print "version = $rpm_info[1]\n";
#    print "release = $rpm_info[2]\n";
#    print "arch    = $rpm_info[3]\n";

    end_routine();
    return(@rpm_info);
}

# --------------------------------------------------------
# rpm_package_string_from_header()
# 
# --------------------------------------------------------

sub rpm_package_string_from_header {
    begin_routine();

    my @version = @_;

    end_routine();
#    return("$version[0]-$version[1]-$version[2] (arch=$version[3])");
    return("$version[0]-$version[1]-$version[2].$version[3]");
}

sub rpm_arch_from_filename {
    begin_routine();

    my $rpm = shift;
    my $config_arch;

    # Trim suffix of .rpm 

#    if ($rpm =~ m/(\S+).rpm$/ ) {
#	$rpm = $1;
#    }

    if( $rpm =~ /^\S+.x86_64$/ ) {
	$config_arch = "x86_64"; 
    } elsif( $rpm =~ /^\S+.i386$/ ) {
	$config_arch = "i386"; 
    } elsif( $rpm =~ /^\S+.i686$/ ) {
	$config_arch = "i686"; 
    } elsif( $rpm =~ /^\S+.486$/ ) {
	$config_arch = "i486"; 
    } elsif( $rpm =~ /^\S+.586$/ ) {
	$config_arch = "i586"; 
    } elsif( $rpm =~ /^\S+.noarch$/ ) {
	$config_arch = "noarch"; 
    } else {
	MYERROR("Unknown RPM architecture -> $rpm\n");
    }

    end_routine();
    return($config_arch);
}

sub verify_expected_md5sum {
    begin_routine();

    my $file = shift;		# rpm file
    my $md5  = shift; 		# expected md5sum from input file

    my $local_md5 = md5sum_file($file);

    if($md5 ne $local_md5) {
	ERROR  ("RPM md5sums to not match for $file\n");
	ERROR  (" --> desired    = $md5\n");
	MYERROR(" --> local file = $md5\n");
    }

    return;
    end_routine;
}

sub md5sum_file {
    begin_routine();

    my $file = shift;
    my $digest = "";

    eval{
	open(FILE, $file) || MYERROR("Unable to access file for md5 calculation: $file");
	my $ctx = Digest::MD5->new;
	$ctx->addfile(*FILE);
	$digest = $ctx->hexdigest;
	close(FILE);
    };

    if($@){
	print $@;
	return "";
    }

    end_routine();
    return $digest;

}

sub validate_rpm_option {
    begin_routine();
    my $option = shift;
    my $rpm_mapping = "";

    INFO("Validating rpm option = $option\n");

    if( $option eq "NODEPS" )  {
	end_routine;
	return("--nodeps ");
    } elsif ( $option eq "IGNORESIZE" ) {
	end_routine;
	return("--ignoresize ");
    } elsif ( $option =~ m/RELOCATE:(\S+):(\S+)/ ) {
	end_routine;
	return("--relocate $1=$2 ");
    } else {
	end_routine;
	WARN("   [WARN]: Ignoring unsupported RPM option type -> $option\n");
	return("");
    }
}

1;

