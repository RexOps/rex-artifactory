package Artifactory::Deploy;

use Rex -base;
use Artifactory;
use DM::Helper;
use DateTime;
use Rex::Apache::Inject qw/Properties/;
use File::Basename 'basename';

require Exporter;
use vars qw(@EXPORT);
use base qw(Exporter);
use IO::All;
use Data::Dumper;

@EXPORT = qw(deploy);

sub deploy {
  my (%options) = @_;

  # first download the package from artifactory
  # into tmp folder
  my $file;

  #### todo:
  # propertie file handling, must be a seperate module
  LOCAL {
    run "rm -rf tmp-dl"; # first clean up
    mkdir "tmp-dl";

    Rex::Logger::info("Downloading artifactory package: $options{repository} / $options{package} / $options{version}.");
    $file = Artifactory::download {
      %options,
      to => "tmp-dl/",
    };

    Rex::Logger::info("File $file downloaded.");

    if(exists $options{inject}) {
      # extract file
      my $config_file = $options{inject_to};

      rmdir "tmp-inject";
      mkdir "tmp-inject";
      extract "../tmp-dl/$file", to => "tmp-inject";
      my ($config_file_path) = qx{find tmp-inject -name $config_file};
      $config_file_path =~ s/[\r\n]//gms;

      my @lines = io("$config_file_path.template")->slurp;
      chomp @lines;

      my @replaced;
      for my $line (@lines) {
        next if( $line =~ m/^#/ );
        next if( $line =~ m/^$/ );
        $line =~ s/[\r\n]//gms;

        my ($key, $val) = $line =~ m/^(.*?)\s?[=:\t]\s?(.*)$/;

        if(exists $options{inject}->{$key}) {
          my $new_line = "$key=" . $options{inject}->{$key} . "\n";
          $new_line >> io("$config_file_path.new");
          push @replaced, $key;
        }
        elsif(exists $options{inject}->{"$key.enc"}) {
          my $new_line = "$key=" . decrypt_string( $options{inject}->{"$key.enc"} ) . "\n";
          $new_line >> io("$config_file_path.new");
          push @replaced, $key;
        }
        else {
          $line .= "\n";
          $line >> io("$config_file_path.new");
        }
      }

      mv "$config_file_path.new", $config_file_path;

      # rezip file
      rm "tmp-dl/$file";
      run "cd tmp-inject ; zip -r ../tmp-dl/$file *";

      if($? != 0) {
        die "Error compressing new configuration archive with new properties from Foreman.";
      }

      rmdir "tmp-inject";
    }
  };

  Rex::Logger::info("Uploading tmp/$file to /tmp/$file.");
  # 2nd upload the package to the target system
  upload "tmp-dl/$file", "/tmp/$file";

  my $today             = DateTime->now;
  my $timestamp         = $today->ymd("-") . "_" . $today->hms("-");
  my $extract_directory = (exists $options{prefix} ? $options{prefix} : "") . $timestamp;
  my $extract_target    = $options{to} . "/" . $extract_directory;

  if(! exists $options{prefix} ) {
    # no prefix, so use target directory directly
    $extract_target = $options{to};
  }

  # extract the archive
  sudo sub { mkdir $extract_target, %options; };

  Rex::Logger::info("Extracting /tmp/file to $options{to}");
  sudo sub { extract "/tmp/$file", %options, to => $extract_target; };

  # Link
  if(exists $options{current_link} && $options{current_link} == TRUE) {
    Rex::Logger::info("Creating current link.");
    sudo sub {
      my $out = run "ln -snf $extract_target $options{to}/current 2>&1";
    };
  }

  # 3rd clean up temporary files
  Rex::Logger::info("Cleaning up.");
  rm "/tmp/$file";

  return $extract_directory;
}

1;
