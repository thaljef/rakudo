# Operations we can do on Supplies. Note, many of them need to compose
# the Supply role into classes they create along the way, so they must
# be declared outside of Supply.

my class SupplyOperations is repr('Uninstantiable') {
    my @secret;

    # Private versions of the methods to relay events to subscribers, used in
    # implementing various operations.
    my role PrivatePublishing {
        method !more(\msg) {
            for self.tappers {
                .more().(msg)
            }
            Nil;
        }

        method !done() {
            for self.tappers {
                if .done { .done().() }
            }
            Nil;
        }

        method !quit($ex) {
            for self.tappers {
                if .quit { .quit().($ex) }
            }
            Nil;
        }
    }
    
    method for(*@values, :$scheduler = $*SCHEDULER) {
        my class ForSupply does Supply {
            has @!values;
            has $!scheduler;

            submethod BUILD(:@!values, :$!scheduler) {}

            method tap(|c) {
                my $closed = False;
                my $sub = self.Supply::tap(|c, closing => { $closed = True });
                $!scheduler.cue(
                    {
                        for @!values -> \val {
                            last if $closed;
                            $sub.more().(val);
                        }
                        if !$closed && $sub.done -> $l { $l() }
                    },
                    :catch(-> $ex { if !$closed && $sub.quit -> $t { $t($ex) } })
                );
                $sub
            }
        }
        ForSupply.new(:@values, :$scheduler)
    }

    method interval($interval, $delay = 0, :$scheduler = $*SCHEDULER) {
        my class IntervalSupply does Supply {
            has $!scheduler;
            has $!interval;
            has $!delay;

            submethod BUILD(:$!scheduler, :$!interval, :$!delay) {}

            method tap(|c) {
                my $cancellation;
                my $sub = self.Supply::tap(|c, closing => { $cancellation.cancel() });
                $cancellation = $!scheduler.cue(
                    {
                        state $i = 0;
                        $sub.more().($i++);
                    },
                    :every($!interval), :in($!delay)
                );
                $sub
            }
        }
        IntervalSupply.new(:$interval, :$delay, :$scheduler)
    }
    
    method flat(Supply $a) {
        my class FlatSupply does Supply does PrivatePublishing {
            has $!source;
            
            submethod BUILD(:$!source) { }
            
            method tap(|c) {
                my $source_tap;
                my $sub = self.Supply::tap(|c, closing => { $source_tap.close() });
                $source_tap = $!source.tap( -> \val {
                      self!more(val.flat)
                  },
                  done => { self!done(); },
                  quit => -> $ex { self!quit($ex) });
                $sub
            }
        }
        FlatSupply.new(:source($a))
    }

    method do($a, &side_effect) {
        on -> $res {
            $a => sub (\val) { side_effect(val); $res.more(val) }
        }
    }

    method grep(Supply $a, &filter) {
        my class GrepSupply does Supply does PrivatePublishing {
            has $!source;
            has &!filter;
            
            submethod BUILD(:$!source, :&!filter) { }
            
            method tap(|c) {
                my $source_tap;
                my $sub = self.Supply::tap(|c, closing => { $source_tap.close() });
                $source_tap = $!source.tap( -> \val {
                      if (&!filter(val)) { self!more(val) }
                  },
                  done => { self!done(); },
                  quit => -> $ex { self!quit($ex) }
                );
                $sub
            }
        }
        GrepSupply.new(:source($a), :&filter)
    }

    method uniq(Supply $a, :&as, :&with) {
        my class UniqSupply does Supply does PrivatePublishing {
            has $!source;
            has &!as;
            has &!with;

            submethod BUILD(:$!source, :&!as, :&!with) { }
            
            method tap(|c) {
                my $source_tap;
                my $sub = self.Supply::tap(|c, closing => { $source_tap.close() });
                my &more = do {
                    if &!with and &!with !=== &[===] {
                        my @seen;  # should be Mu, but doesn't work in settings
                        my Mu $target;
                        &as
                          ?? -> \val {
                              $target = &!as(val);
                              if @seen.first({ &!with($target,$_) } ) =:= Nil {
                                  @seen.push($target);
                                  self!more(val);
                              }
                          }
                          !! -> \val {
                              if @seen.first({ &!with(val,$_) } ) =:= Nil {
                                  @seen.push(val);
                                  self!more(val);
                              }
                          };
                    }
                    else {
                        my $seen := nqp::hash();
                        my str $target;
                        &as
                          ?? -> \val {
                              $target = nqp::unbox_s(&!as(val).WHICH);
                              unless nqp::existskey($seen, $target) {
                                  nqp::bindkey($seen, $target, 1);
                                  self!more(val);
                              }
                          }
                          !! -> \val {
                              $target = nqp::unbox_s(val.WHICH);
                              unless nqp::existskey($seen, $target) {
                                  nqp::bindkey($seen, $target, 1);
                                  self!more(val);
                              }
                          };
                    }
                };
                $source_tap = $!source.tap( &more,
                  done => { self!done(); },
                  quit => -> $ex { self!quit($ex) }
                );
                $sub
            }
        }
        UniqSupply.new(:source($a), :&as, :&with);
    }

    method squish(Supply $a, :&as, :&with is copy) {
        &with //= &[===];
        my class SquishSupply does Supply does PrivatePublishing {
            has $!source;
            has &!as;
            has &!with;

            submethod BUILD(:$!source, :&!as, :&!with) { }
            
            method tap(|c) {
                my $source_tap;
                my $sub = self.Supply::tap(|c, closing => { $source_tap.close() });
                my &more = do {
                    my Mu $last = @secret;
                    my Mu $target;
                    &as
                      ?? -> \val {
                          $target = &!as(val);
                          unless &!with($target,$last) {
                              $last = $target;
                              self!more(val);
                          }
                      }
                      !! -> \val {
                          unless &!with(val,$last) {
                              $last = val;
                              self!more(val);
                          }
                      };
                };
                $source_tap = $!source.tap( &more,
                  done => { self!done(); },
                  quit => -> $ex { self!quit($ex) }
                );
                $sub
            }
        }
        SquishSupply.new(:source($a), :&as, :&with);
    }
    
    method map(Supply $a, &mapper) {
        my class MapSupply does Supply does PrivatePublishing {
            has $!source;
            has &!mapper;
            
            submethod BUILD(:$!source, :&!mapper) { }
            
            method tap(|c) {
                my $source_tap;
                my $sub = self.Supply::tap(|c, closing => { $source_tap.close() });
                $source_tap = $!source.tap( -> \val {
                      self!more(&!mapper(val))
                  },
                  done => { self!done(); },
                  quit => -> $ex { self!quit($ex) });
                $sub
            }
        }
        MapSupply.new(:source($a), :&mapper)
    }

    method rotor(Supply $s, $elems is copy, $overlap is copy ) {

        $elems   //= 2;
        $overlap //= 1;
        return $s if $elems == 1 and $overlap == 0;  # nothing to do

        my class RotorSupply does Supply does PrivatePublishing {
            has $!source;
            has $.elems;
            has $.overlap;
            
            submethod BUILD(:$!source, :$!elems, :$!overlap) { }
            
            method tap(|c) {
                my $source_tap;
                my $tap = self.Supply::tap(|c, closing => { $source_tap.close() });

                my @batched;
                sub flush {
                    self!more([@batched]);
                    @batched.splice( 0, +@batched - $!overlap );
                }

                $source_tap = $!source.tap( -> \val {
                      @batched.push: val;
                      flush if @batched.elems == $!elems;
                  },
                  done => {
                      flush if @batched;
                      self!done();
                  },
                  quit => -> $ex { self!quit($ex) });
                $tap
            }
        }
        RotorSupply.new(:source($s), :$elems, :$overlap)
    }

    method batch(Supply $s, :$elems, :$seconds ) {

        return $s if (!$elems or $elems == 1) and !$seconds;  # nothing to do

        my class BatchSupply does Supply does PrivatePublishing {
            has $!source;
            has $.elems;
            has $.seconds;
            
            submethod BUILD(:$!source, :$!elems, :$!seconds) { }
            
            method tap(|c) {
                my $source_tap;
                my $tap = self.Supply::tap(|c, closing => { $source_tap.close() });

                my @batched;
                my $last_time;
                sub flush {
                    self!more([@batched]);
                    @batched = ();
                }

                my &more = do {
                    if $!seconds {
                        $last_time = time div $!seconds;

                        $!elems # and $!seconds
                          ??  -> \val {
                              @batched.push: val;
                              if @batched.elems == $!elems {
                                  flush;
                              }
                              else {
                                  my $this_time = time div $!seconds;
                                  if $this_time != $last_time {
                                      flush;
                                      $last_time = $this_time;
                                  }
                              }
                          }
                          !! -> \val {
                              my $this_time = time div $!seconds;
                              if $this_time != $last_time {
                                  flush;
                                  $last_time = $this_time;
                              }
                          }
                    }
                    else { # just $!elems
                        -> \val {
                            @batched.push: val;
                            if @batched.elems == $!elems {
                                flush;
                            }
                        }
                    }
                }
                $source_tap = $!source.tap( &more,
                  done => {
                      flush if @batched;
                      self!done();
                  },
                  quit => -> $ex { self!quit($ex) });
                $tap
            }
        }
        BatchSupply.new(:source($s), :$elems, :$seconds)
    }
    
    method merge(*@s) {

        @s.shift unless @s[0].DEFINITE;  # lose if used as class method
        return Supply unless +@s;        # nothing to be done
        return @s[0]  if +@s == 1;       # nothing to be done

        my $dones = 0;
        on -> $res {
            @s => {
                more => -> \val { $res.more(val) },
                done => { $res.done() if ++$dones == +@s }
            },
        }
    }
    
    method zip(*@s, :&with is copy) {

        @s.shift unless @s[0].DEFINITE;  # lose if used as class method
        return Supply unless +@s;        # nothing to be done
        return @s[0]  if +@s == 1;       # nothing to be done

        my &infix:<op> = &with // &[,]; # hack for [[&with]] parse failure
        my @values = ( [] xx +@s );
        on -> $res {
            @s => -> $val, $index {
                @values[$index].push($val);
                if all(@values) {
                    $res.more( [op] @values>>.shift );
                }
            }
        }
    }
}
