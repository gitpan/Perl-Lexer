#!/usr/bin/env perl
use 5.010;
use strict;
use warnings;
use FindBin;
use HTTP::Tiny;
use JSON::PP;
use Archive::Tar;
use version;

# XXX: 5.8.8 and 5.8.9 also have debug_tokens.
my $min_version = version->parse('5.010000');

my $ua = HTTP::Tiny->new;

my @perls;
{
    my %seen;
    my $res = $ua->get("http://api.metacpan.org/v0/release/_search?q=distribution:perl&fields=download_url,date&size=500&sort=date:desc");
    die "Can't get perl versions" unless $res->{success};
    @perls =
        map {+{version => $_->[0], url => $_->[2]}}
        grep {not ($seen{$_->[1]}++)}
        sort {$a->[1] <=> $b->[1] || $a->[0] cmp $b->[0]}
        grep {defined $_ && $_->[1] >= $min_version}
        map {
            my $url = $_->{fields}{download_url};
            $url =~ s/\.bz2$/\.gz/;
            my $ret;
            if (my ($version) = $url =~ /perl-(5\.\d+\.\d+(?:\-RC\d+)?)\.tar\.gz$/) {
                my $v = $version; $v =~ s/\-RC\d+$//;
                $ret = [$version, version->parse($v), $url];
            }
            $ret;
        }
        @{ decode_json($res->{content})->{hits}{hits} || [] };
}

my $src_dir = "$FindBin::Bin/src";
my $dst_dir = "$FindBin::Bin/../lib/Perl/gen";

mkdir $src_dir unless -d $src_dir;
mkdir $dst_dir unless -d $dst_dir;

open my $map, '>', "$dst_dir/token_info_map.h";

my %seen;
my %prev;
for my $perl (@perls) {
    my $version = $perl->{version};
    next if $seen{$version}++;
    say "processing $version...";
    my $file = "$src_dir/perl-$version.tar.gz";
    if (!-f $file) {
        say "downloading $version...";
        my $res = $ua->mirror($perl->{url}, $file);
        unless ($res->{success}) {
            warn "Can't download $version";
            next;
        }
    }
    my $tar = Archive::Tar->new($file, 1);

    for my $name (qw/perly.h toke.c/) {
        (my $vname = $name) =~ s/\./-$version./;
        unlink "$src_dir/$vname" if -f "$src_dir/$vname";
        $tar->extract_file("perl-$version/$name", "$src_dir/$vname");
    }

    my $perly = '';
    {
        my $src = "$src_dir/perly-$version.h";
        my $dst = "$dst_dir/perly-$version.h";
        open my $in, '<', $src;
        open my $out, '>', $dst;
        while(<$in>) {
            next if /PERL_CORE|PERL_IN_TOKE_C/;
            print $out $_;
            $perly .= $_;
        }
        close $in;
        close $out;
    }

    my $token_info = '';
    {
        my $src = "$src_dir/toke-$version.c";
        my $dst = "$dst_dir/token_info-$version.h";
        open my $in, '<', $src;
        open my $out, '>', $dst;
        say $out qq{#include "perly-$version.h"};
        my $flag;
        while(<$in>) {
            if (/^(?:enum token_type|static struct debug_token)/) {
                $flag = 1;
            }
            if ($flag) {
                print $out $_;
                $token_info .= $_;
                $flag = 0 if /^\s*$/;
            }
        }
    }

    my ($revision, $major, $minor) = split /\./, $version;
    $minor =~ s/\-RC\d+//;

    my $include_version = $version;
    if ($prev{perly} && $prev{perly} eq $perly &&
        $prev{token_info} && $prev{token_info} eq $token_info &&
        $minor  # should always keep 5.x.0 for clarity
    ) {
        unlink "$dst_dir/perly-$version.h";
        unlink "$dst_dir/token_info-$version.h";
        $include_version = $prev{version};
    } else {
        $prev{perly} = $perly;
        $prev{token_info} = $token_info;
        $prev{version} = $version;
    }

    my $if = keys %seen > 1 ? "elif" : "if";

    print $map <<"MAP";
#$if PERL_VERSION == $major && PERL_SUBVERSION == $minor
#include "token_info-$include_version.h"
MAP
}

# fallback to the latest (so that we don't always need to rush everytime a new version of perl is released)
if ($prev{perly} && $prev{token_info} && $prev{version}) {
    {
        open my $out, '>', "$dst_dir/perly-latest.h";
        print $out $prev{perly};
    }
    {
        open my $out, '>', "$dst_dir/token_info-latest.h";
        say $out qq{#include "perly-latest.h"};
        print $out $prev{token_info};
    }
    my ($revision, $major, $minor) = split /\./, $perls[-1]->{version};
    print $map <<"MAP";
#elif PERL_VERSION > $major || (PERL_VERSION == $major && PERL_SUBVERSION > $minor)
#include "token_info-latest.h"
MAP
}

print $map <<"MAP";
#else
#error "No support for this perl version"
#endif
MAP
