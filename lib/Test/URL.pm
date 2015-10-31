package Test::URL;

use 5.010001;
use strict;
use warnings;
use Time::HiRes qw( time );
use Data::Dumper;

require Exporter;

our @ISA = qw(Exporter);

# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.

# This allows declaration	use Test::URL ':all';
# If you do not need this, moving things directly into @EXPORT or @EXPORT_OK
# will save memory.
our %EXPORT_TAGS = ( 'all' => [ qw(
	
) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(
	error
	timeout
	user_agent
	request
	verbose
	server
);

our $VERSION = '0.01';

my %timer;

# Preloaded methods go here.
sub new
{
	my $package = shift;

	my $self = bless({}, $package);

	# Defaults
	$self->{timeout} = 5;
	$self->{user_agent} = "test_url/0.1";

	return $self;
}
sub get
{
	my ($self,$url,$headers) = @_;

	# Prepare Request
	$url =~ /^(https?)\:\/\/([\w\-\.]+)([\:\d]*)(\/.*)$/;
	my $protocol = $1;
	my $host = $2;
	my $port = $3;
	my $query_string = $4;

	# Default Port
	$port = 80 unless $port =~ /^\d+$/;

	# Default Headers
	$headers->{"User-Agent"} = $self->{user_agent} unless ($headers->{"User-Agent"});

	$self->{request} = "GET $query_string HTTP/1.0\r\n";
	foreach my $header(sort keys %{$headers})
	{
		$self->{request} .= $header.": ".$headers->{$header}."\r\n";
	}
	$self->{request} .= "\r\n";

	my $response = $self->communicate($host,$port,$self->{request});
	return $response;
}
sub post
{
	my ($self,$url,$headers,$parameters) = @_;

	# Prepare Request
	$url =~ /^(https?)\:\/\/([\w\-\.]+)([\:\d]*)(\/.*)$/;
	my $protocol = $1;
	my $host = $2;
	my $port = $3;
	my $query_string = $4;

	# Default Port
	$port = 80 unless $port =~ /^\d+$/;

	$self->{request} = "POST $query_string HTTP/1.0\n";
	foreach my $header(sort keys %{$headers})
	{
		$self->{request} .= $header.": ".$headers->{$header}."\n";
	}
	$self->{request} .= "\n";

	$self->{response} = $self->communicate($host,$port,$self->{request});

	return $self->{response};
}
sub communicate
{
	my ($self,$host,$port,$request) = @_;

	if ($self->{server})
	{
		$host = $self->{server};
	}
	print "Connecting to $host at port $port\n" if ($self->{verbose});
	use IO::Socket;

	# Connect to Server
	my $start_time = time;
	my $socket;
	unless ($socket = new IO::Socket::INET (
		PeerAddr	=> $host,
		PeerPort	=>  $port,
		Proto		=> 'tcp',
		Timeout		=> $self->{timeout},
		Blocking	=> 0,
	))
	{
		$self->{error} = "Couldn't connect to Server $host: $!\n";
		return 0;
	}
	$socket->autoflush(1);
	#$socket->timeout($self->{timeout});

	$timer{'connect'} = time - $start_time;

	# Disable Output Buffering
	$| = 1;

	# Send Request
	print STDOUT "Sending Request:\n" if ($self->{verbose});
	$socket->send($request);
	$timer{'send'} = time - $timer{'connect'} - $start_time;
	print STDOUT "Awaiting Response\n" if ($self->{verbose});

	# Get First Byte
	my $response;
	my $timeout = $self->{timeout} + time;
	while (1)
	{
		$socket->recv($response,1);
		last if ($response);
		if (time > $timeout)
		{
			$self->{error} = "Timeout waiting for response";
			return 0;
		}
	}
	$timer{'first_byte'} = time - $timer{send} - $timer{connect} - $start_time;

	my $buffer;
	
	# Load Headers
	$timeout = $self->{timeout} + time;
	my $section = "status line";
	my $document;
	while (1)
	{
		$socket->recv($buffer,128,MSG_DONTWAIT);
		$timer{'receive'} = time - $timer{'send'} - $timer{connect} - $start_time;
		$response .= $buffer;
		$document->{size} += length($buffer);

		if ($section eq "status line")
		{
			print "Collecting status line\n" if ($self->{verbose} > 8);
			if ($response =~ /\r*\n/)
			{
				($document->{'status line'},$response) = split(/\r*\n/,$response,2);
				$document->{'status line'} =~ /HTTP\/\d\.\d\s(\d+)\s(.+)/;
				$document->{code} = $1;
				$document->{status} = $2;
				$section = "headers";
			}
		}
		if ($section eq "headers")
		{
			print "Collecting headers\n" if ($self->{verbose} > 8);
			while ($section eq "headers" && $response =~ /\r*\n/)
			{
				my $header;
				($header,$response) = split(/\r*\n/,$response,2);
				if ($header)
				{
					print "Collected Header $header\n" if ($self->{verbose} > 7);
					my ($label,$value) = split(/\:\s*/,$header,2);
					$document->{headers}->{$label} = $value;
				}
				else
				{
					$section = "body";
				}
			}
		}
		if ($section eq "body")
		{
			#print "Collecting body [".($timeout - time)."]\n" if ($self->{verbose} > 8);
			if ($document->{headers}->{'Content-Length'})
			{
				# Calculate Rest of Message
				my $remaining = $document->{headers}->{'Content-Length'} - length($response);
				$document->{content} .= $response;
				while ($remaining)
				{
					print "Waiting for $remaining bytes of body\n" if ($self->{verbose} > 8);
					$socket->recv($buffer,$remaining);
					my $chars = length($buffer);
					$remaining -= $chars;
					print "Chars returned for body: $chars\n" if ($self->{verbose} > 8);
					$document->{content} .= $buffer;
					$document->{size} += $chars;
				}
				return $document;
			}
			$document->{content} .= $response;
			$response = '';
			if ($document->{content} =~ /\<\/html\>$/)
			{
				return $document;
			}
		}
		if ($buffer)
		{
			#$timeout = $self->{timeout} + time;
			$timeout = time + 1;
			#print "Buffer: $buffer\n";
		}
		elsif (time > $timeout)
		{
			#$self->{error} = "Timeout waiting for response";
			#print "Got $response\n";
			return $document;
		}
	}
	close $socket;
	return $response;
}
sub statistics
{
	my $self = shift;
	my $response = {
		timer => \%timer
	};
	return $response;
	#print Dumper %timer;
}
1;
__END__
# Below is stub documentation for your module. You'd better edit it!

=head1 NAME

Test::URL - Perl extension for blah blah blah

=head1 SYNOPSIS

  use Test::URL;
  blah blah blah

=head1 DESCRIPTION

Stub documentation for Test::URL, created by h2xs. It looks like the
author of the extension was negligent enough to leave the stub
unedited.

Blah blah blah.

=head2 EXPORT

None by default.



=head1 SEE ALSO

Mention other useful documentation such as the documentation of
related modules or operating system documentation (such as man pages
in UNIX), or any relevant external documentation such as RFCs or
standards.

If you have a mailing list set up for your module, mention it here.

If you have a web site set up for your module, mention it here.

=head1 AUTHOR

Anthony Caravello, E<lt>tcaravello@wal-tcaravello.ad.buydomains.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2012 by Anthony Caravello

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.16.1 or,
at your option, any later version of Perl 5 you may have available.


=cut
