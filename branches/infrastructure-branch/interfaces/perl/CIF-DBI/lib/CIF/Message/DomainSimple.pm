package CIF::Message::DomainSimple;
use base 'CIF::Message::Domain';

use strict;
use warnings;

use CIF::Message::DomainWhitelist;
use CIF::Message::Inet;
use CIF::Message::InetWhitelist;
use CIF::Message::MaliciousDomain;
use CIF::Message::FastfluxDomain;
use CIF::Message::SuspiciousNameserver;
use CIF::Message::Infrastructure;
use Regexp::Common qw/net/;
use Regexp::Common::net::CIDR;

sub insert {
    my $self = shift;
    my $info = {%{+shift}};

    my $domain = $info->{'address'};
    return 0 if(CIF::Message::DomainWhitelist::isWhitelisted($domain));

    my @ids;
    my @results = CIF::Message::Domain::getrdata($info->{'nsres'},$domain);
    foreach my $r (@results){
        my $rdata;
        my $description = $info->{'description'};
        my $impact = $info->{'impact'};
        my $severity = $info->{'severity'};
        my $bucket = 'CIF::Message::MaliciousDomain';

        if($r->{'address'}){
            $rdata = $r->{'address'};
            $description = $description.' '.$rdata if($rdata);
            if($r->{'type'} eq 'NS'){
                $severity = 'low';
            }
        }
        if(lc($info->{'impact'} =~ /fastflux/)){
            $bucket = 'CIF::Message::FastfluxDomain';
            $impact = 'fastflux domain '.$domain;
            $description = $impact;
            $description .= ' '.$rdata if($rdata);
        }
        if(lc($info->{'impact'} =~ /nameserver/)){
            $bucket = 'CIF::Message::SuspiciousNameserver';
            $description = $impact.' '.$domain;
            $description .= ' '.$rdata if($rdata);
        }

        if($r->{'nameserver'}){
            $bucket = 'CIF::Message::SuspiciousNameserver';
            $impact = 'suspicious nameserver';
            $impact .= ' fastflux' if(lc($info->{'impact'}) =~ /fastflux/);
            $impact .= ' '.$domain;
            $description = $impact.' '.$rdata;
            $severity = 'low';
        }
        if($r->{'cname'}){
            $rdata = $r->{'cname'};
            $description = $impact.' '.$domain.' '.$rdata;
        }

        my ($as,$network,$ccode,$rir,$date,$as_desc);
        if($rdata && $rdata =~ /^$RE{net}{IPv4}/){
            ($as,$network,$ccode,$rir,$date,$as_desc) = CIF::Message::Inet::asninfo($rdata);
        } else {
            next if(CIF::Message::DomainWhitelist::isWhitelisted($rdata));
        }

        my $id = $bucket->insert({
            relatedid   => $info->{'relatedid'},
            address     => $domain,
            source      => $info->{'source'},
            confidence  => $info->{'confidence'},
            severity    => $severity,
            impact      => $impact,
            description => $description,
            detecttime  => $info->{'detecttime'},
            class       => $r->{'class'},
            ttl         => $r->{'ttl'},
            type        => $r->{'type'},
            rdata       => $rdata,
            asn         => $as,
            asn_desc    => $as_desc,
            cidr        => $network,
            cc          => $ccode,
            rir         => $rir,
            restriction => $info->{'restriction'},
            alternativeid => $info->{'alternativeid'},
            alternativeid_restriction => $info->{'alternativeid_restriction'},
        });
        push(@ids,$id);
        my $confidence = ($info->{'confidence'}) ? ($info->{'confidence'} - 2) : 0;
        $severity = ($severity eq 'high') ? 'medium' : 'low';

        next if($r->{'type'} eq 'CNAME');
        next unless($rdata && $rdata =~ /^$RE{net}{IPv4}/);
        next if(CIF::Message::Inet::isPrivateAddress($rdata));
        next if(CIF::Message::InetWhitelist::isWhitelisted($rdata));
        CIF::Message::Infrastructure->insert({
            relatedid   => $id->uuid(),
            address     => $rdata,
            impact      => $impact,
            source      => $info->{'source'},
            description => $description,
            confidence  => $confidence,
            severity    => $severity,
            detecttime  => DateTime->from_epoch(epoch => time()),
            restriction => $info->{'restriction'},
            asn         => $as,
            asn_desc    => $as_desc,
            cidr        => $network,
            cc          => $ccode,
            rir         => $rir,
            cidr        => $network,
            alternativeid   => $info->{'alternativeid'},
            alternativeid_restriction => $info->{'alternativeid_restriction'},
        });
    }
    return($ids[$#ids]);
}

1;
