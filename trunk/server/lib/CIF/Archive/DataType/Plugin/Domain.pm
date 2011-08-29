package CIF::Archive::DataType::Plugin::Domain;
use base 'CIF::Archive::DataType';

use strict;
use warnings;

use Module::Pluggable require => 1, search_path => [__PACKAGE__], except => qr/SUPER$/;
use Net::Abuse::Utils qw(:all);
use Digest::MD5 qw/md5_hex/;
use Digest::SHA1 qw/sha1_hex/;

__PACKAGE__->table('domain');
__PACKAGE__->columns(Primary => 'id');
__PACKAGE__->columns(All => qw/id uuid address md5 sha1 type confidence source guid severity restriction detecttime created/);
__PACKAGE__->columns(Essential => qw/id uuid address md5 sha1 type confidence source guid severity restriction detecttime created/);
__PACKAGE__->sequence('domain_id_seq');

sub prepare {
    my $class = shift;
    my $info = shift;

    return unless($info->{'address'});
    $info->{'address'} = lc($info->{'address'});
    
    my $address = $info->{'address'};
    return(undef) unless($address =~ /^[a-z0-9.-]+\.[a-zA-Z]{2,5}$/);
    $info->{'md5'} = md5_hex($address);
    $info->{'sha1'} = sha1_hex($address);

    return(1);
}

sub insert {
    my $self = shift;
    my $info = shift;

    my $tbl = $self->table();
    foreach($self->plugins()){
        if(my $t = $_->prepare($info)){
            $self->table($tbl.'_'.$t);
        }
    }

    my $uuid    = $info->{'uuid'};

    my $id = eval { 
        $self->SUPER::insert({
            uuid        => $uuid,
            address     => $info->{'address'},
            type        => $info->{'type'} || 'A',
            md5         => $info->{'md5'},
            sha1        => $info->{'sha1'},
            source      => $info->{'source'},
            confidence  => $info->{'confidence'},
            severity    => $info->{'severity'} || 'null',
            restriction => $info->{'restriction'} || 'private',
            detecttime  => $info->{'detecttime'},
            guid        => $info->{'guid'},
        }); 
    };
    if($@){
        return(undef,$@) unless($@ =~ /duplicate key value violates unique constraint/);
        $id = CIF::Archive->retrieve(uuid => $uuid);
    }

    ## TODO -- turn this into a for-loop to ensure the capture of all sub-domains
    ## eg: test1.test2.yahoo.com -- test2.yahoo.com gets indexed.
    if($info->{'address'} !~ /^[a-z0-9-]+\.[a-z]{2,5}$/){
        $info->{'address'} =~ m/([a-z0-9-]+\.[a-z]{2,5})$/;
        my $addr = $1;
        eval { $self->SUPER::insert({
            uuid    => $uuid,
            address => $addr,
            type    => $info->{'type'} || 'A',
            md5     => md5_hex($addr),
            sha1    => sha1_hex($addr),
            source  => $info->{'source'},
            confidence  => $info->{'confidence'},
            severity    => $info->{'severity'} || 'null',
            restriction => $info->{'restriction'} || 'private',
            detecttime  => $info->{'detecttime'},
            guid        => $info->{'guid'},
        })};
    }
    $self->table($tbl);
    return($id);    
}

sub lookup {
    my $self = shift;
    my $info = shift;
    my $address = $info->{'query'};

    return(undef) unless($address && lc($address) =~ /^[a-z0-9.-]+\.[a-z]{2,5}$/);
    $address = md5_hex($address);
    my $sev = $info->{'severity'};
    my $conf = $info->{'confidence'};
    my $restriction = $info->{'restriction'};

    if($info->{'guid'}){
        return($self->search__lookup(
            $address,
            $sev,
            $conf,
            $restriction,
            $info->{'guid'},
            $info->{'limit'}
        ));
    }
    return(
        $self->search_lookup(
            $address,
            $sev,
            $conf,
            $restriction,
            $info->{'apikey'},
            $info->{'limit'}
        )
    );
}

## TODO -- fix this to work with feed
sub isWhitelisted {
    my $self = shift;
    my $addr = shift;

    my @bits = reverse(split(/\./,$addr));
    my $tld = $bits[0];
    my @array;
    push(@array,$tld);
    my @hashes;
    foreach(1 ... $#bits){
        push(@array,$bits[$_]);
        my $d = join('.',reverse(@array));
        $d = md5_hex($d);
        $d = "'".$d."'";
        push(@hashes,$d);
    }
    my $sql .= join(' OR md5 = ',@hashes);
    $sql =~ s/^/md5 = /;

    $sql .= qq{\nORDER BY detecttime DESC, created DESC, id DESC};
    my $t = $self->table();
    $self->table('domain_whitelist');
    my @recs = $self->retrieve_from_sql($sql);
    $self->table($t);
    return @recs;
}

sub feed {
    my $class = shift;
    my $info = shift;

    my @feeds;
    $info->{'key'} = 'address';
    my $ret = $class->_feed($info);
    push(@feeds,$ret) if($ret);

    foreach($class->plugins()){
        my $r = $_->_feed($info);
        push(@feeds,$r) if($r);
    }
    return(\@feeds);
}

## TODO -- fix this 
__PACKAGE__->set_sql('feed' => qq{
    SELECT DISTINCT on (__TABLE__.uuid) __TABLE__.uuid, address, confidence, archive.data
    FROM __TABLE__
    LEFT JOIN apikeys_groups ON __TABLE__.guid = apikeys_groups.guid
    LEFT JOIN archive ON __TABLE__.uuid = archive.uuid
    WHERE
        NOT EXISTS (
            SELECT uuid FROM domain_whitelist dw
                WHERE
                    dw.confidence >= 25
                    AND dw.md5 = __TABLE__.md5
        )
        AND detecttime >= ?
        AND __TABLE__.confidence >= ?
        AND severity >= ?
        AND __TABLE__.restriction <= ?
        AND apikeys_groups.uuid = ?
    ORDER BY __TABLE__.uuid ASC, __TABLE__.id ASC, confidence DESC, severity DESC, __TABLE__.restriction ASC
    LIMIT ?
});

## TODO -- maybe change this to an md5 lookup?
## the only con is that we'd lose fuzzy searches
## eg: yahoo.com would result with example.yahoo.com results

__PACKAGE__->set_sql('lookup' => qq{
    SELECT __TABLE__.id,__TABLE__.uuid, archive.data 
    FROM __TABLE__
    LEFT JOIN apikeys_groups ON __TABLE__.guid = apikeys_groups.guid
    LEFT JOIN archive ON archive.uuid = __TABLE__.uuid
    WHERE 
        md5 = ?
        AND severity >= ?
        AND confidence >= ?
        AND __TABLE__.restriction <= ?
        AND apikeys_groups.uuid = ?
    ORDER BY __TABLE__.detecttime DESC, __TABLE__.created DESC, __TABLE__.id DESC
    LIMIT ?
});

__PACKAGE__->set_sql('_lookup' => qq{
    SELECT __TABLE__.id,__TABLE__.uuid 
    FROM __TABLE__
    WHERE md5 = ?
    AND severity >= ?
    AND confidence >= ?
    AND restriction <= ?
    AND guid = ?
    LIMIT ?
});

1;
__END__

=head1 NAME

 CIF::Archive::DataType::Plugin::Domain - CIF::Archive plugin for indexing domain data

=head1 SEE ALSO

 http://code.google.com/p/collective-intelligence-framework/
 CIF::Archive

=head1 AUTHOR

 Wes Young, E<lt>wes@barely3am.comE<gt>

=head1 COPYRIGHT AND LICENSE

 Copyright (C) 2011 by Wes Young (claimid.com/wesyoung)
 Copyright (C) 2011 by the Trustee's of Indiana University (www.iu.edu)
 Copyright (C) 2011 by the REN-ISAC (www.ren-isac.net)

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10.0 or,
at your option, any later version of Perl 5 you may have available.

=cut
