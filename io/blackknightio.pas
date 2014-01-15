program blackknightio;
{
 Make I/O on a shift register (74LS673) coupled to an input multiplexer (74150)
 using a raspberry pi and only 4 GPIO lines

 (c) 2013 Frederic Pasteleurs <frederic@askarel.be>

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program or from the site that you downloaded it
 from; if not, see <http://www.gnu.org/licenses/>.

 The PiGPIO library included in this repository is (c) 2013 Gábor Szöllösi
}

// This is a quick hack to check if everything works

uses PiGpio, sysutils, crt, keyboard, strutils, baseunix, ipc;

TYPE    TDbgArray= ARRAY [0..15] OF string[15];
        TRegisterbits=bitpacked array [0..15] of boolean; // Like a word: a 16 bits bitfield
        TLotsofbits=bitpacked array [0..63] of boolean; // A shitload of bits to abuse. 64 bits should be enough. :-)
        TSHMVariables=RECORD // What items should be exposed for IPC.
                PIDofmain:TPid;
                Inputs, outputs: TRegisterbits;
                state, Config :TLotsofbits;
                Command: string;
                SHMMsg:string;
                end;
        TConfigTextArray=ARRAY [0..63] of string[20];

CONST   CLOCKPIN=7;  // 74LS673 pins
        STROBEPIN=8;
        DATAPIN=25;
        READOUTPIN=4; // Output of 74150

        bits:array [false..true] of char=('0', '1');
        // Hardware bug: i got the address lines reversed while building the board.
        // Using a lookup table to mirror the address bits
        BITMIRROR: array[0..15] of byte=(0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15);

        // Various timers, in milliseconds (won't be accurate at all, but time is not critical)
        COPENWAIT=5000;


        // Available outputs on 74LS673. Outputs Q0 to Q3 are connected to the address inputs of the 74150
        Q15=0; Q14=1; Q13=2; Q12=3; Q11=4; Q10=5; Q9=6; Q8=7; Q7=8; Q6=9; Q5=10; Q4=11;
        // Use more meaningful descriptions of the outputs in the code
        // Outputs Q4, Q12, Q13, Q14 and Q15 are not used for the moment. Status LED maybe ?
        BUZZER_OUTPUT=Q11;
        BATTERY_RELAY=Q10;
        MAGLOCK1_RELAY=Q9;
        MAGLOCK2_RELAY=Q8;
        DOOR_STRIKE_RELAY=Q7;
        LIGHT_CONTROL_RELAY=Q6;
        DOORBELL_INHIBIT_RELAY=Q5;
        // Available inputs from the 74150
        I15=15; I14=14; I13=13; I12=12; I11=11; I10=10; I9=9; I8=8; I7=7; I6=6; I5=5; I4=4; I3=3; I2=2; I1=1; I0=0;
        // Use more meaningful descriptions of the inputs in the code
        // Inputs OPTO4, IN3, IN2 and IN1 are not used for the moment.
        // The numbers below correspond to the numbers printed on the screw terminals
        IN11=I0; IN10=I1; IN9=I2; IN8=I3; IN7=I4; IN6=I5; IN5=I6; IN4=I7; IN3=I8; IN2=I9; IN1=I10; OPTO1=I12; OPTO2=I13; OPTO3=I14; OPTO4=I15;
        PANIC_SENSE=I11;
        DOORBELL1=OPTO1;
        DOORBELL2=OPTO2;
        DOORBELL3=OPTO3;
        BOX_TAMPER_SWITCH=IN11;
        TRIPWIRE_LOOP=IN10;
        MAGLOCK1_RETURN=IN9;
        MAGLOCK2_RETURN=IN8;
        DOORHANDLE=IN7;
        LIGHTS_ON_SENSE=IN6;
        DOOR_CLOSED_SWITCH=IN5;
        MAILBOX=IN4;     // Of course we'll have physical mail notification. :-)
        IS_CLOSED=false;
        IS_OPEN=true;
        DBGINSTATESTR: Array [IS_CLOSED..IS_OPEN] of string[5]=('closed', 'open');
        DBGOUTSTATESTR: Array [false..true] of string[5]=('On', 'Off');
        CFGSTATESTR: Array [false..true] of string[8]=('Disabled','Enabled');
        DBGOUT: TDbgArray=('Q15 not used', 'Q14 not used', 'Q13 not used', 'Q12 not used', 'buzzer', 'battery', 'mag1 power', 'mag2 power', 'strike',
                                'light', 'bell inhib.', 'Q4 not used', '74150 A3', '74150 A2', '74150 A1', '74150 A0');
        DBGIN: TDbgArray=('TAMPER BOX','TRIPWIRE','MAG1 CLOSED','MAG2 CLOSED','HANDLE','LIGHT ON','DOOR SWITCH','MAILBOX','IN 3',
                                'IN 2','IN 1','PANIC SWITCH','DOORBELL 1','DOORBELL 2','DOORBELL 3','OPTO 4');
        // offsets in status/config bitfields
        SC_MAGLOCK1=0; SC_MAGLOCK2=1; SC_TRIPWIRE_LOOP=2; SC_BOX_TAMPER_SWITCH=3; SC_MAILBOX=4; SC_BUZZER=5;
        // Status report only
        S_DEMOMODE=63; S_TUESDAY=62;

        MessagesSTR: array [1..16] of string=(
                'Door is unlocked',
                'Door is open',
                'Door is closed',
                'Door is locked by maglock 1',
                'Door is locked by maglock 2',
                'Unlocking maglock 1',
                'Unlocking maglock 2',
                'Unlocking door strike',
                'TRIPWIRE LOOP BROKEN: POSSIBLE BREAK-IN',
                'TAMPER ALERT: THE CONTROL BOX IS BEING OPENED',
                'You got mail',
                'Warning: Maglock 1 is on but the shoe is not there',
                'Warning: Maglock 2 is on but the shoe is not there',
                'Hallway light is on',
                'PANIC BUTTON PRESSED: MAGLOCKS PHYSICALLY DISCONNECTED',
                'Tuesday mode: Ring doorbell to enter'
                );

        // Static config
        STATIC_CONFIG_STR: TConfigTextArray=('Maglock 1',
                                             'Maglock 2',
                                             'Tripwire loop',
                                             'Box tamper',
                                             'Mail notification',
                                             'buzzer',
                                             '',
                                             '', '', '', '', '', '', '', '',  '', '', '', '', '', '', '', '', '', '', '',
                                             '', '', '', '', '', '', '', '', '',  '', '', '', '', '', '', '', '', '', '',
                                             '', '', '', '', '', '', '', '', '',  '', '', '', '', '', '', '', '', '', '');

        STATIC_CONFIG: TLotsOfBits=(true,  // SC_MAGLOCK1 (Maglock 1 installed)
                                    false, // SC_MAGLOCK2 (Maglock 2 not installed)
                                    true,  // SC_TRIPWIRE_LOOP (Tripwire installed)
                                    true,  // SC_BOX_TAMPER_SWITCH (Tamper switch installed)
                                    true,  // SC_MAILBOX (Mail detection installed)
                                    true,  // SC_BUZZER (Let it make some noise)
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false,
                                    false, // Unused
                                    false  // Unused
                                    );

VAR     GPIO_Driver: TIODriver;
        GpF: TIOPort;

///////////// COMMON LIBRARY FUNCTIONS /////////////

// Return gray-encoded input
function graycode (inp: longint): longint;
begin
 graycode:=(inp shr 1) xor inp;
end;

function word2bits (inputword: word): TRegisterbits;
begin
 word2bits:=TRegisterbits (inputword); // TRegisterbits is a word-sized array of bits
end;

function bits2word (inputbits: TRegisterbits): word;
begin
 bits2word:=word (inputbits);
end;

function bits2str (inputbits: TRegisterbits): string;
var i: byte;
    s: string;
begin
 s:='';
 for i:=(bitsizeof (TRegisterbits)-1) downto 0 do s:=s+bits[inputbits[i]];
 bits2str:=s;
end;

// For IPC stuff (sending commands)
Procedure sendcommand (shmkey: TKey; cmd, comment: string);
var  shmid: longint;
     SHMPointer: ^TSHMVariables;
begin
 shmid:=shmget (shmkey, sizeof (TSHMVariables), IPC_CREAT or IPC_EXCL or 438);
    if shmid = -1 then
     begin
      shmid:=shmget (shmkey, sizeof (TSHMVariables), 0);
      // Add test for shmget error here ?
      SHMPointer:=shmat (shmid, nil, 0);
      writeln (paramstr (0),': Sending command ', cmd, ' to PID ', SHMPointer^.PIDOfMain);
      SHMPointer^.command:=cmd;
      if comment = '' then SHMPointer^.SHMMsg:='<no message provided>'
                      else SHMPointer^.SHMMsg:=comment;
     end
    else
     begin // We may have just created an instance. Killing it.
      writeln (paramstr (0),': not started.');
      shmctl (shmid, IPC_RMID, nil);
      halt (1);
     end;
end;

function busy_delay (var waittime: word; timetowait: word): boolean;
begin
 case waittime of
  0:busy_delay:=true; // Time's up !!
  65535:              // Reset timer
   begin
    waittime:=timetowait shr 4;
    busy_delay:=false;
   end;
  else                // Tick...
   begin
    waittime:=waittime -1;
    busy_delay:=false;
   end;
 end;
end;

procedure busy_delay_reset (var waittime: word);
begin
 waittime:=65535;
end;

// Needed functions: event logging and buzzer handling



procedure dump_config (bits: TLotsofbits; textdetail:TConfigTextArray );
var i: byte;
begin
 for i:=0 to 63 do if textdetail[i] <> '' then writeln ('Config option ', i, ': ', textdetail[i], ': ', CFGSTATESTR[bits[i]]);
end;

///////////// DEBUG FUNCTIONS /////////////

function debug_alterinput(inbits: TRegisterbits): TRegisterbits;
var key: string;
    K: TKeyEvent;
begin
 K:=PollKeyEvent; // Check for keyboard input
 if k<>0 then // Key pressed ?
  begin
   k:=TranslateKeyEvent (GetKeyEvent);
   key:= KeyEventToString (k);
   case key of
    '0': if inbits[0] then inbits[0]:=false else inbits[0]:=true;
    '1': if inbits[1] then inbits[1]:=false else inbits[1]:=true;
    '2': if inbits[2] then inbits[2]:=false else inbits[2]:=true;
    '3': if inbits[3] then inbits[3]:=false else inbits[3]:=true;
    '4': if inbits[4] then inbits[4]:=false else inbits[4]:=true;
    '5': if inbits[5] then inbits[5]:=false else inbits[5]:=true;
    '6': if inbits[6] then inbits[6]:=false else inbits[6]:=true;
    '7': if inbits[7] then inbits[7]:=false else inbits[7]:=true;
    '8': if inbits[8] then inbits[8]:=false else inbits[8]:=true;
    '9': if inbits[9] then inbits[9]:=false else inbits[9]:=true;
    'a': if inbits[10] then inbits[10]:=false else inbits[10]:=true;
    'b': if inbits[11] then inbits[11]:=false else inbits[11]:=true;
    'c': if inbits[12] then inbits[12]:=false else inbits[12]:=true;
    'd': if inbits[13] then inbits[13]:=false else inbits[13]:=true;
    'e': if inbits[14] then inbits[14]:=false else inbits[14]:=true;
    'f': if inbits[15] then inbits[15]:=false else inbits[15]:=true;
    else writeln ('Invalid key: ',key);
   end;
  end;
 sleep (16); // Emulate the real deal
 debug_alterinput:=inbits;
end;

// Decompose a word into bitfields with description
procedure debug_showbits (inputbits: TRegisterbits; screenshift: byte; description: TDbgArray );
var i, oldx, oldy: byte;
begin
 oldx:=wherex; oldy:=wherey;
 for i:=0 to 15 do
  begin
   description[i][0]:=char (15);// Trim length
   gotoxy (1 + screenshift, i + 1); write ( bits[inputbits[i]], ' ', description[i]);
  end;
  gotoxy (oldx, oldy);
//  writeln;
end;

///////////// CHIP HANDLING FUNCTIONS /////////////

// Send out a word to the 74LS673
procedure write74673 (clockpin, datapin, strobepin: byte; data: TRegisterbits);
var i: byte;
begin
 for i:=0 to 15 do
 begin
  GpF.SetBit (clockpin);
  if data[i] then GpF.SetBit (datapin) else GpF.Clearbit (datapin);
  GpF.ClearBit (clockpin);
 end;
// GpF.SetBit (datapin); // Is that line needed ?
 GpF.SetBit (strobepin);
 GpF.Clearbit (strobepin);
end;

// Do an I/O cycle on the board
function io_673_150 (clockpin, datapin, strobepin, readout: byte; data:TRegisterbits): TRegisterbits;
var i: byte;
    gpioword: word;
begin
 gpioword:=0;
 for i:=0 to 15 do
  begin
   write74673 (clockpin, datapin, strobepin, word2bits ((bits2word (data) and $0fff) or (BITMIRROR[graycode (i)] shl $0c)) );
   sleep (1); // Give the electronics time for propagation
   gpioword:=(gpioword or (ord (GpF.GetBit (readout)) shl graycode(i) ) );
  end;
 io_673_150:=word2bits (gpioword);
end;

///////////// MAIN BLOCK /////////////
var  shmkey: TKey;
     shmid: longint;
     progname:string;
     inputs, outputs, oldin, oldout: TRegisterbits;
     SHMPointer: ^TSHMVariables;
     CurrentState: TLotsOfBits;
     demomode: boolean;
     open_wait: word;

begin
 outputs:=word2bits (0);
 oldin:=word2bits (12345);
 oldout:=word2bits (12345);
 busy_delay_reset (open_wait);

 progname:=paramstr (0) + #0;
 shmkey:=ftok (pchar (@progname[1]), ord ('t'));

 case paramstr (1) of
  'stop':
    sendcommand (shmkey, 'stop', paramstr (2));
  'open':
    sendcommand (shmkey, 'open', paramstr (2));

  'start':
   begin
    shmid:=shmget (shmkey, sizeof (TSHMVariables), IPC_CREAT or IPC_EXCL or 438);
    if shmid = -1 then
     begin
      writeln (paramstr (0),': not starting: already running.');
      halt (1);
     end;
    SHMPointer:=shmat (shmid, nil, 0);
    fillchar (SHMPointer^, sizeof (TSHMVariables), 0);
    SHMPointer^.PIDOfMain:=fpGetPid;
    clrscr;
    if GPIO_Driver.MapIo then
     begin
      demomode:=false;
      GpF := GpIo_Driver.CreatePort(GPIO_BASE, CLOCK_BASE, GPIO_PWM);
      GpF.SetPinMode (CLOCKPIN, OUTPUT);
      GpF.setpinmode (STROBEPIN, OUTPUT);
      GpF.setpinmode (DATAPIN, OUTPUT);
      GpF.setpinmode (READOUTPIN, INPUT);
     end
     else
      begin
       gotoxy (1,17); writeln ('WARNING: Error mapping registry: GPIO code disabled, running in demo mode.');
       demomode:=true;
       inputs:=word2bits (65535); // Open contact = 1
       initkeyboard;
      end;
    SHMPointer^.state[S_DEMOMODE]:=demomode;
    gotoxy (1,18);

    repeat // Start of the main loop. Should run at around 62,5 Hz. The I/O operation has a hard-coded 16 ms delay (propagation time through the I/O chips)
     if demomode then inputs:=debug_alterinput (inputs)
                 else inputs:=io_673_150 (CLOCKPIN, DATAPIN, STROBEPIN, READOUTPIN, outputs);

     // Do lock logic shit !!
     if inputs[PANIC_SENSE] = IS_OPEN then
      begin // PANIC MODE (topmost priority)
       writeln ('PANIC');
      end
      else
      begin
       if SHMPointer^.command = 'open' then
        begin
         if not busy_delay (open_wait, COPENWAIT) then
          begin
//           writeln ('Opening door. Reason: ', SHMPointer^.shmmsg);
           outputs[MAGLOCK1_RELAY]:=false;
           outputs[MAGLOCK2_RELAY]:=false;
           outputs[DOOR_STRIKE_RELAY]:=true;
           outputs[BUZZER_OUTPUT]:=true;
          end
          else
          begin
           writeln ('relocking door.');
           busy_delay_reset (open_wait);
           SHMPointer^.command:='';
          end;
        end
        else
        begin
         if STATIC_CONFIG[SC_MAGLOCK1] then outputs[MAGLOCK1_RELAY]:=true;
         if STATIC_CONFIG[SC_MAGLOCK2] then outputs[MAGLOCK2_RELAY]:=true;
         outputs[DOOR_STRIKE_RELAY]:=false;
         outputs[BUZZER_OUTPUT]:=false;
       end;
      end;
     // End of lock logic shit.

     // Tamper processing
     if STATIC_CONFIG[SC_TRIPWIRE_LOOP] then
      if inputs[TRIPWIRE_LOOP] = IS_OPEN then
       begin
        writeln ('TRIPWIRE BROKEN');
       end
       else
       begin
        writeln ('tripwire ok');
       end;

     if STATIC_CONFIG[SC_BOX_TAMPER_SWITCH] then
      if inputs[BOX_TAMPER_SWITCH] = IS_OPEN then
       begin
        writeln ('CONTROL BOX BREACHED');
       end
       else
       begin
        writeln ('control box closed');
       end;

     // Check mail
     if STATIC_CONFIG[SC_MAILBOX] then
      if inputs[MAILBOX] = IS_CLOSED then
       begin
        writeln ('You have mail.');
       end
       else
       begin
        writeln ('No mail.');
       end;

     // Do some housekeeping
     if bits2word (oldout) <> bits2word (outputs) then debug_showbits (outputs, 0, DBGOUT);
     if bits2word (oldin) <> bits2word (inputs) then debug_showbits (inputs, 17, DBGIN);
     // Return current state to the shm buffer
     SHMPointer^.inputs:=inputs;
     SHMPointer^.outputs:=outputs;
     SHMPointer^.state:=CurrentState;
     SHMPointer^.Config:=STATIC_CONFIG;
     oldout:=outputs;
     oldin:=inputs;
    until SHMPointer^.command = 'stop';
    outputs:=word2bits (0);
    debug_showbits (outputs, 0, DBGOUT);
    if SHMPointer^.shmmsg <> '' then writeln ('Quitting for reason: ',SHMPointer^.shmmsg);
    if demomode then donekeyboard
                else write74673 (CLOCKPIN, DATAPIN, STROBEPIN, outputs);
    shmctl (shmid, IPC_RMID, nil);
   end;

   'test':
    begin
    end;

   'forget':
    begin
     writeln ('Forgetting everything about my running processes (NOT RECOMMENDED)');
     shmid:=shmget (shmkey, sizeof (TSHMVariables), 0);
     shmctl (shmid, IPC_RMID, nil);
    end;

   'diag':
    begin
     dump_config (STATIC_CONFIG, STATIC_CONFIG_STR);
    end;

   '':
   begin
    writeln ('Usage: ', paramstr (0), ' [start|stop|test|open|diag]');
    halt (1);
   end;
 end;
// writeln;writeln;

end.
