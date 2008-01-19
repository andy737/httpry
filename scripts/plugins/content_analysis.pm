#!/usr/bin/perl -w

#
#  ----------------------------------------------------
#  httpry - HTTP logging and information retrieval tool
#  ----------------------------------------------------
#
#  Copyright (c) 2005-2007 Jason Bittel <jason.bittel@gmail.com>
#

package content_analysis;

use warnings;
use Time::Local qw(timelocal);

# -----------------------------------------------------------------------------
# GLOBAL CONSTANTS
# -----------------------------------------------------------------------------
my $FLOW_TIMEOUT = 300;

my $HOST_WEIGHT = 0.0;
my $PATH_WEIGHT = 0.50;
my $QUERY_WEIGHT = 0.75;

# -----------------------------------------------------------------------------
# GLOBAL VARIABLES
# -----------------------------------------------------------------------------
# Counter variables
my $flow_cnt = 0;
my $flow_line_cnt = 0;
my $flow_min_len = 999999;
my $flow_max_len = 0;
my $max_concurrent = 0;

# Data structures
my %active_flow = ();       # Holds metadata about each active flow
my %active_flow_data = ();  # Holds individual flow data lines
my %scored_flow = ();
#my %history = ();         # Holds cache of content checks to avoid matching
my %terms = ();           # Dictionary of terms and corresponding weights

# -----------------------------------------------------------------------------
# Plugin core
# -----------------------------------------------------------------------------

&main::register_plugin(__PACKAGE__);

sub new {
        return bless {};
}

sub init {
        my $self = shift;
        my $plugin_dir = shift;
        my $term;
        my $weight;

        if (&load_config($plugin_dir) == 0) {
                return 0;
        }

        # Read in query terms and weights from input file
        # TODO: add more error checking
        open(TERMS, "$terms_file") or die "Error: Cannot open $terms_file: $!\n";
                foreach (<TERMS>) {
                        chomp;
                        next if /^#/; # Skip comments

                        ($term, $weight) = split / /, $_;
                        $terms{$term} = $weight;
                }
        close(TERMS);

        # Remove any existing text files so they don't accumulate
        opendir(DIR, $output_dir) or die "Error: Cannot open directory $output_dir: $!\n";
                foreach (grep /^scored_.+\.txt$/, readdir(DIR)) {
                        unlink;
                }
        closedir(DIR);

        return 1;
}

sub main {
        my $self = shift;
        my $record = shift;
        my $curr_line;
        my $decoded_uri;

        # Retain this variable across function calls
        BEGIN {
                my $epoch_boundary = 0;

                sub get_epoch_boundary { return $epoch_boundary; }
                sub set_epoch_boundary { $epoch_boundary = shift; }
        }

        # Make sure we really want to be here
        return unless (exists $record->{"direction"} && ($record->{"direction"} eq '>'));
        return unless exists $record->{"timestamp"};
        return unless exists $record->{"source-ip"};
        return unless exists $record->{"host"};
        return unless exists $record->{"request-uri"};

        $decoded_uri = $record->{"request-uri"};
        $decoded_uri =~ s/%25/%/g; # Sometimes '%' chars are double encoded
        $decoded_uri =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;

        $curr_line = "$record->{'timestamp'}\t$record->{'dest-ip'}\t$record->{'host'}\t$decoded_uri";

        # Convert timestamp of current record to epoch seconds
        $record->{"timestamp"} =~ /(\d\d)\/(\d\d)\/(\d\d\d\d) (\d\d)\:(\d\d)\:(\d\d)/;
        $epochstamp = timelocal($6, $5, $4, $2, $1 - 1, $3);

        if ((keys %active_flow) > $max_concurrent) {
                $max_concurrent = keys %active_flow;
        }

        # Only call timeout_flows() if we've crossed a time boundary; i.e., 
        # if there's actually a chance for a flow to end
        if (&get_epoch_boundary() <= $epochstamp) {
                &set_epoch_boundary(&timeout_flows($epochstamp));
        }

        # Begin a new flow if one doesn't exist
        if (!exists $active_flow{$record->{"source-ip"}}) {
                $flow_cnt++;

#                $active_flow{$record->{"source-ip"}}->{"start_time"} = $record->{"timestamp"};
                $active_flow{$record->{"source-ip"}}->{"length"} = 0;
                $active_flow{$record->{"source-ip"}}->{"score"} = 0;
        }

#        $active_flow{$record->{"source-ip"}}->{"end_time"} = $record->{"timestamp"};
        $active_flow{$record->{"source-ip"}}->{"end_epoch"} = $epochstamp;
        $active_flow{$record->{"source-ip"}}->{"length"}++;

        push(@{ $active_flow_data{$record->{"source-ip"}} }, $curr_line);

        &content_check("$record->{'host'}$record->{'request-uri'}", $record->{"source-ip"});

        return;
}

sub end {
        &timeout_flows(0);
        &write_summary_file();

        return;
}

# -----------------------------------------------------------------------------
# Load config file and check for required options
# -----------------------------------------------------------------------------
sub load_config {
        my $plugin_dir = shift;

        # Load config file; by default in same directory as plugin
        if (-e "$plugin_dir/" . __PACKAGE__ . ".cfg") {
                require "$plugin_dir/" . __PACKAGE__ . ".cfg";
        }

        # Check for required options and combinations
        if (!$output_file) {
                print "Error: No output file provided\n";
                return 0;
        }

        if (!$terms_file) {
                print "Error: No terms file provided\n";
                return 0;
        }

        $output_dir = "." if (!$output_dir);
        $output_dir =~ s/\/$//; # Remove trailing slash

        return 1;
}

# -----------------------------------------------------------------------------
#
# -----------------------------------------------------------------------------
sub content_check {
#        my $hostname = shift;
#        my $uri = shift;
#        my $ip = shift;
#        my $term;
        my $uri = shift;
        my $ip = shift;
        my $term;

        $uri =~ /^([^\/?#]*)?([^?#]*)(\?([^#]*))?(#(.*))?/;

        my $host = $1;
        my $path = $2;
        my $query = $4;

        # TODO: $host may not always be set here
        foreach $term (keys %terms) {
                if ($host && index($host, $term) >= 0) {
                        $active_flow{$ip}->{"score"} += $terms{$term} * $HOST_WEIGHT;
#                        $active_flow{$ip}->{"terms"}->{$term}++;
#                        $active_flow{$ip}->{"hosts"}->{$host}++;
                }

                if ($path && index($path, $term) >= 0) {
                        $active_flow{$ip}->{"score"} += $terms{$term} * $PATH_WEIGHT;
#                        $active_flow{$ip}->{"terms"}->{$term}++;
#                        $active_flow{$ip}->{"hosts"}->{$host}++;
                }

                if ($query && index($query, $term) >= 0) {
                        $active_flow{$ip}->{"score"} += $terms{$term} * $QUERY_WEIGHT;
#                        $active_flow{$ip}->{"terms"}->{$term}++;
#                        $active_flow{$ip}->{"hosts"}->{$host}++;
                }
        }

#        $history{$hostname} = -1 if (!defined $history{$hostname});
#        $history{$uri} = -1 if (!defined $history{$uri});
#
#        return 1 if (($history{$hostname} == 1) || ($history{$uri} == 1));
#        return 0 if (($history{$hostname} == 0) && ($history{$uri} == 0));
#
#        foreach $term (@terms) {
#                if (index($hostname, $term) >= 0) {
#                        $history{$hostname} = 1;
#                        $tagged_terms{$ip}->{$term}++;
#                        return 1;
#                }
#
#                if (index($uri, $term) >= 0) {
#                        $history{$uri} = 1;
#                        $tagged_terms{$ip}->{$term}++;
#                        return 1;
#                }
#        }
#
#        $history{$hostname} = 0;
#        $history{$uri} = 0;

        return;
}

# -----------------------------------------------------------------------------
# Handle end of flow duties: flush to disk and delete hash entries; passing an
# epochstamp value causes all flows inactive longer than $FLOW_TIMEOUT to be
# flushed, while passing a zero forces all active flows to be flushed.
#
# Returns the next potential epoch boundary at which flows could time out.
# -----------------------------------------------------------------------------
sub timeout_flows {
        my $epochstamp = shift;
        my $flow_str;
        my $epoch_diff;
        my $max_epoch_diff = 0;
        my $ip;

        foreach $ip (keys %active_flow) {
                if ($epochstamp) {
                        $epoch_diff = $epochstamp - $active_flow{$ip}->{"end_epoch"};
                        if ($epoch_diff <= $FLOW_TIMEOUT) {
                                $max_epoch_diff = $epoch_diff if ($epoch_diff > $max_epoch_diff);

                                next;
                        }
                }

                # Update flow statistics
                $flow_min_len = $active_flow{$ip}->{"length"} if ($active_flow{$ip}->{"length"} < $flow_min_len);
                $flow_max_len = $active_flow{$ip}->{"length"} if ($active_flow{$ip}->{"length"} > $flow_max_len);
                $flow_line_cnt += $active_flow{$ip}->{"length"};

                # Save score information only if a score has been applied
                if ($active_flow{$ip}->{"score"} > 0) {
                        $scored_flow{$ip}->{"num_flows"}++;
                        $scored_flow{$ip}->{"score"} += $active_flow{$ip}->{"score"};

                        &append_scored_file($ip);
                }

                delete $active_flow{$ip};
                delete $active_flow_data{$ip};
        }

        return $epochstamp + ($FLOW_TIMEOUT - $max_epoch_diff);
}

# -----------------------------------------------------------------------------
# Append flow data to a detail file based on client IP
# -----------------------------------------------------------------------------
sub append_scored_file {
        my $ip = shift;
        my $line;

        open(HOSTFILE, ">>$output_dir/scored_$ip.txt") or die "Error: Cannot open $output_dir/scored_$ip.txt: $!\n";

        print HOSTFILE '>' x 80 . "\n";
        foreach $line (@{ $active_flow_data{$ip} }) {
                print HOSTFILE $line, "\n";
        }
        print HOSTFILE '<' x 80 . "\n";

        close(HOSTFILE);

        return;
}

# -----------------------------------------------------------------------------
# Collect and write summary information to specified output file
# -----------------------------------------------------------------------------
sub write_summary_file {
        my $ip;
        my $scored_flow_cnt = 0;

        open(OUTFILE, ">$output_file") or die "Error: Cannot open $output_file: $!\n";

        print OUTFILE "\n\nCLIENT FLOWS SUMMARY\n\n";
        print OUTFILE "Generated:      " . localtime() . "\n";
        print OUTFILE "Flow count:     $flow_cnt\n";
        print OUTFILE "Flow lines:     $flow_line_cnt\n";
        print OUTFILE "Max Concurrent: $max_concurrent\n";
        print OUTFILE "Min/Max/Avg:    ";
        if ($flow_cnt > 0) {
                print OUTFILE "$flow_min_len/$flow_max_len/" . sprintf("%d", $flow_line_cnt / $flow_cnt) . "\n";
        } else {
                print OUTFILE "0/0/0\n";
        }

        &partition_scores();

        # Delete flows and associated files from the lower partition
        foreach $ip (keys %scored_flow) {
                if ($scored_flow{$ip}->{"cluster"} == 0) {
                        delete $scored_flow{$ip};
                        unlink "$output_dir/scored_$ip.txt";
                }
        }

        if (scalar(keys %scored_flow) == 0) {
                print OUTFILE "\n\n*** No scored flows found\n";
                close(OUTFILE);
                
                return;
        }

        map { $scored_flows_cnt += $scored_flow{$_}->{"num_flows"} } keys %scored_flow;

        print OUTFILE "\nTerms file:     $terms_file\n";
        print OUTFILE "Scored IPs:     " . (keys %scored_flow) . "\n";
        print OUTFILE "Scored flows:   $scored_flows_cnt\n\n";

        foreach $ip (sort { $scored_flow{$b}->{"score"} <=> $scored_flow{$a}->{"score"} } keys %scored_flow) {
                print OUTFILE sprintf("%.2f", $scored_flow{$ip}->{"score"}) . "\t$scored_flow{$ip}->{'num_flows'}\t$ip\n";
        }

        close(OUTFILE);

        return;
}

# -----------------------------------------------------------------------------
# Dynamically partition scored flows into a high and a low set using the
# k-means clustering algorithm; this allows us to skim the top scoring flows
# off the top without setting arbitrary thresholds or levels 
#
# K-means code originally taken from: http://www.perlmonks.org/?node_id=541000
# Many subsequent modifications and changes have been made
# -----------------------------------------------------------------------------
sub partition_scores() {
        my $ip;
        my $diff;
        my $new_center;
        my $max_score = 0;
        my $centroid;
        my @center = (0, 1);
        my @members;

        # Normalize all values into the range 0..1
        foreach $ip (keys %scored_flow) {
                if ($scored_flow{$ip}->{"score"} > $max_score) { $max_score = $scored_flow{$ip}->{"score"}; }
        }
        map { $scored_flow{$_}->{"norm_score"} = sprintf("%.1f", $scored_flow{$_}->{"score"} / $max_score) } keys %scored_flow;

        do {
                $diff = 0;

                # Assign points to nearest center
                foreach $ip (keys %scored_flow) {
                        my $dist0 = abs $scored_flow{$ip}->{"norm_score"} - $center[0];
                        my $dist1 = abs $scored_flow{$ip}->{"norm_score"} - $center[1];

                        if ($dist0 < $dist1) {
                                $scored_flow{$ip}->{"cluster"} = 0;
                        } else {
                                $scored_flow{$ip}->{"cluster"} = 1;
                        }
                }

                # Compute new centers
                foreach $centroid (0..$#center) {

                        @members = sort map { $scored_flow{$_}->{"norm_score"} }
                                   grep { $scored_flow{$_}->{"cluster"} == $centroid } keys %scored_flow;

                        # Calculate new center based on median
                        # TODO: this could go out of bounds
                        $new_center = $members[int(scalar @members / 2) - 1];
                        print "new center ($centroid): $new_center\n";

                        $diff += abs $center[$centroid] - $new_center;
                        $center[$centroid] = $new_center;
                }
        } while ($diff > 0.01);

        return;
}

1;