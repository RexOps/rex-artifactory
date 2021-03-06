package Artifactory;

=pod

=head1 NAME

Artifactory - Artifactory Zugriff

=head1 DESCRIPTION

This module is to list the versions available for a java artifact in artifactory
and to download an artifact to a specific directory.

=head1 CONFIGURATION

For this module it is important to configure the artifactory system and also the
authentication credentials inside I</etc/rex/rex.conf>

 artifactory:
   host: artifactory.your-network.tld
   path: artifactory
   proto: http
   user: XXXXXX
   password: YYYYYYY

=head1 USAGE

To list the versions of a artifact use this command:

 $ rex -qM Artifactory Artifactory:list \
      --repository=releases-local \
      --package=some.package.foo

To download an artifact use this command:

 $ rex -qM Artifactory Artifactory:download \
      --repository=releases-local \
      --package=some.package.foo \
      --version=1.3 \
      --to=/path/to/download/folder \
      [--suffix=production]



=cut

use Rex::Commands;

use Data::Dumper;
use Mojo::UserAgent;
use Carp;

desc "List the available versions of an artifact.";
task "list", make {
  my $params = shift;

  die "No repository given" if ! exists $params->{repository};
  die "No package given"    if ! exists $params->{package};

  # to get the available versions out of a maven repository,
  # we need to read the maven-metadata.xml file.
  # this can be easily done with Mojo::DOM perl module.
  my $ret = make_artifactory_request($params->{repository},
    $params->{package},
    "maven-metadata.xml");

  if($ret) {
    my $versions = $ret->res->dom->metadata->versioning->versions;
    for my $version ( $versions->children('version')->each ) {
      print $version->text . "\n";
    }
  }
  else {
    Rex::Logger::info("No versions found.", "warn");
  }
};

desc "Download an artifact from artifactory.";
sub download {
  my $params = shift;

  # there is a download-size protection in the library at 10MB
  # so we need to set it at a higher level.
  $ENV{MOJO_MAX_MESSAGE_SIZE} = 1024*1024*1024*1024;

  die "No --repository= given" if ! exists $params->{repository};
  die "No --package= given"    if ! exists $params->{package};
  die "No --version= given"    if ! exists $params->{version};
  die "No location given where the download should be saved. (Parameter: --to=)"
    if ! exists $params->{to};

  $params->{package} =~ s/\//./g;

  my ($package_name) = ($params->{package} =~ m/\.([^\.]+)$/);

  # in the very first step, we need to check if there is a maven-metadata.xml
  # inside the version directory. this is especially for snapshot repos
  my $mvn_tx = make_artifactory_request($params->{repository},
    $params->{package},
    "$params->{version}/maven-metadata.xml");

  my ($file_format, $file_name, $file_version);

  my ($download_artifact);

  if( $mvn_tx->success ) {
    # there is a maven-metadata.xml, so we need to parse it to get the lastest
    # version.
    my $dom = $mvn_tx->res->dom;

    #my $snapshot_artifacts  = $dom->metadata->versioning->snapshotVersions;
    my $check = $dom->find("metadata > versioning > snapshotVersions");
    if($check->each) {
      my ($snapshot_artifacts)  = $dom->find("metadata > versioning > snapshotVersions")->each;
      ($download_artifact) = sort { 
                                  my ($bo) = $b->children("value")->each;
                                  my ($ao) = $a->children("value")->each;

                                  $bo->text cmp $ao->text 
                                }

                                  grep {
                                    my @exts = $_->children("extension")->each;
                                    $exts[0]->text ne "pom"
                                    }   # filter out pom artifacts
                                  $snapshot_artifacts->children('snapshotVersion')->each;

      ($file_version) = $download_artifact->children("value")->each;
      $file_version = $file_version->text;
    }
    else {
      $file_version = $params->{version};
    }
  }
  else {
    $file_version = $params->{version};
  }

  my $dom_ext_col;
  my ($package_format);

  if(! $download_artifact ) {
    Rex::Logger::info("Can't download maven-metadata.xml for your version: $params->{version}. Seems to be a release directory.", "warn");
  }
  else {
    $dom_ext_col = $download_artifact->children("extension");
  }

  Rex::Logger::info("Using download version: $file_version.");

  # then we need to read the pom file of the artifact.
  # with this file we can get the packaging format (jar, war, ear) and a lot of
  # other information. currently we only read the packaging format.
  # in the future it is also possible to read the dependencies from this file.
  my $tx = make_artifactory_request($params->{repository},
    $params->{package},
    "$params->{version}/$package_name-$file_version.pom");

  if( !$tx->success ) {
    die "Error connecting to Artifactory-Server.";
  }

  my $res = $tx->res;

  eval {
    $package_format = get_packaging_from_pom($res->dom);
    1;
  } or do {
    Rex::Logger::info("Found no package in $package_name->$file_version.pom file.", "warn");
    $package_format = $ENV{config_package_format};
  };

  if($package_format eq "pom" && $dom_ext_col && $dom_ext_col->size > 0) {
    my $dom_ext = $dom_ext_col->first;
    $package_format = $dom_ext->text;

    my $dom_class_col = $download_artifact->children("classifier");
    if($dom_class_col->size > 0) {
      #$params->{suffix} = $dom_class_col->first->text;
      $params->{classifier} = $dom_class_col->first->text;
    }
  }

  if(!$package_format || $package_format eq "pom") {
    if(exists $params->{package_format}) {
      $package_format = $params->{package_format};
    }
    else {
      die "Error, no package format found.";
    }
  }

  my $file = "$package_name-$file_version";
  if( exists $params->{suffix} ) {
    $file .= "-$params->{suffix}";
  }

  if(exists $params->{classifier}) {
    $file .= "-$params->{classifier}";
  }

  if(exists $params->{package_format}) {
    $file .= "." . $params->{package_format};
  }
  else {
    $file .= ".$package_format";
  }


  # after collecting all the information, we can download the artifact
  # and save it in the provided directory.
  my $dl_tx = make_artifactory_request($params->{repository},
    $params->{package},
    "$params->{version}/$file");

  if( my $res = $dl_tx->success ) {
    my $download_to = $params->{to} . "/$file";
    $res->content->asset->move_to($download_to);
  }
  else {
    die "Error downloading file ($file).";
  }

  return $file;  
}

task "download", \&download;

# get the type of the archive.
# for example: war, jar, ear
# default: jar
#
# a pom file is a xml document. With Mojo::DOM it is easy to parse such a
# document.
sub get_packaging_from_pom {
  my ($dom) = @_;
  my ($pkg_node_prj) = $dom->children("project")->each;
  my ($pkg_node) = $pkg_node_prj->children("packaging")->each;

  if($pkg_node) {
    return $pkg_node->text;
  }

  return "jar"; # fallback to jar
}

sub make_artifactory_request {
  my ($repository, $package, $url) = @_;
  my $package_path = get_package_path($package);

  my $art_url   = get("artifactory")->{host};
  my $art_user  = get("artifactory")->{user};
  my $art_pass  = get("artifactory")->{password};
  my $art_path  = get("artifactory")->{path} || "artifactory";
  my $art_proto = get("artifactory")->{proto} || "http";

  die "No artifactory url configured in configuration file."      if ! $art_url;
  die "No artifactory user configured in configuration file."     if ! $art_user;
  die "No artifactory password configured in configuration file." if ! $art_pass;

  my $ua = Mojo::UserAgent->new;
  Rex::Logger::info("Requesting: $art_proto://*:*\@$art_url/$art_path/$repository/$package_path/$url");
  $ua->get("$art_proto://$art_user:$art_pass\@$art_url/$art_path/$repository/$package_path/$url");
}

# create the filesystem path out of a package name
# de.filiadata.common.something -> de/filiadata/common/something
sub get_package_path {
  my $package = shift;
  $package =~ s/\./\//g;
  return $package;
}

1;
