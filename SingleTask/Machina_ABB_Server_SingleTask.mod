MODULE Machina_Server

    ! ##     ##    ###     ######  ##     ## #### ##    ##    ###
    ! ###   ###   ## ##   ##    ## ##     ##  ##  ###   ##   ## ##
    ! #### ####  ##   ##  ##       ##     ##  ##  ####  ##  ##   ##
    ! ## ### ## ##     ## ##       #########  ##  ## ## ## ##     ##
    ! ##     ## ######### ##       ##     ##  ##  ##  #### #########
    ! ##     ## ##     ## ##    ## ##     ##  ##  ##   ### ##     ##
    ! ##     ## ##     ##  ######  ##     ## #### ##    ## ##     ##
    !
    !
    !
    ! This file starts a synchronous, single-threaded server on a virtual/real ABB robot,
    ! waits for a TCP client, listens to a stream of formatted string messages,
    ! buffers them parsed into an 'action' struct, and runs a loop to execute them. .
    !
    ! IMPORTANT: make sure to adjust SERVER_IP to your current setup
    !
    ! More info on https://github.com/RobotExMachina
    ! A project by https://github.com/garciadelcastillo
    !
    !
    ! MIT License
    !
    ! Copyright (c) 2018 Jose Luis Garcia del Castillo y Lopez
    !
    ! Permission is hereby granted, free of charge, to any person obtaining a copy
    ! of this software and associated documentation files (the "Software"), to deal
    ! in the Software without restriction, including without limitation the rights
    ! to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    ! copies of the Software, and to permit persons to whom the Software is
    ! furnished to do so, subject to the following conditions:
    !
    ! The above copyright notice and this permission notice shall be included in all
    ! copies or substantial portions of the Software.
    !
    ! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    ! IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    ! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    ! AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    ! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    ! OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    ! SOFTWARE.



    !   __  __ __        __    ___  __      __
    !  |  \|_ /  |   /\ |__) /\ | |/  \|\ |(_
    !  |__/|__\__|__/--\| \ /--\| |\__/| \|__)
    !

    ! An abstract representation of a robotic instruction
    RECORD action
        num id;
        num code;
        string s1;
        ! `Records` cannot contain arrays... :(
        num p1; num p2; num p3; num p4; num p5;
        num p6; num p7; num p8; num p9; num p10;
        num p11;
    ENDRECORD

    ! Server data: change IP from localhost to "192.168.125.1" (typically) if working with a real robot
    CONST string SERVER_IP := "127.0.0.1";
    CONST num SERVER_PORT := 7000;

    ! Useful for handshakes and version compatibility checks...
    CONST string MACHINA_SERVER_VERSION := "1.0.0";

    ! Should program exit on any kind of error?
    VAR bool USE_STRICT := TRUE;

    ! TCP stuff
    VAR string clientIp;
    VAR socketdev serverSocket;
    VAR socketdev clientSocket;

    ! A RAPID-code oriented API:
    !                                         INSTRUCTION P1 P2 P3 P4...
    CONST num INST_MOVEL := 1;              ! MoveL X Y Z QW QX QY QZ
    CONST num INST_MOVEJ := 2;              ! MoveJ X Y Z QW QX QY QZ
    CONST num INST_MOVEABSJ := 3;           ! MoveAbsJ J1 J2 J3 J4 J5 J6
    CONST num INST_SPEED := 4;              ! (setspeed V_TCP [V_ORI V_LEAX V_REAX])
    CONST num INST_ZONE := 5;               ! (setzone FINE TCP [ORI EAX ORI LEAX REAX])
    CONST num INST_WAITTIME := 6;           ! WaitTime T
    CONST num INST_TPWRITE := 7;            ! TPWrite "MSG"
    CONST num INST_TOOL := 8;               ! (settool X Y Z QW QX QY QZ KG CX CY CZ)
    CONST num INST_NOTOOL := 9;             ! (settool tool0)
    CONST num INST_SETDO := 10;             ! SetDO "NAME" ON
    CONST num INST_SETAO := 11;             ! SetAO "NAME" V

    CONST num INST_STOP_EXECUTION := 100;       ! Stops execution of the server module
    CONST num INST_GET_INFO := 101;             ! A way to retreive state information from the server (not implemented)
    CONST num INST_SET_CONFIGURATION := 102;    ! A way to make some changes to the configuration of the server

    ! Characters used for buffer parsing
    CONST string STR_MESSAGE_END_CHAR := ";";
    CONST string STR_MESSAGE_ID_CHAR := "@";
    CONST string STR_MESSAGE_RESPONSE_CHAR := ">";  ! this will be added to infomation request responses (acknowledgments do not include it)

    ! RobotWare 5.x shim
    CONST num WAIT_MAX := 8388608;

    ! State variables representing a virtual cursor of data the robot is instructed to
    PERS tooldata cursorTool;
    PERS wobjdata cursorWObj;
    VAR robtarget cursorTarget;
    VAR jointtarget cursorJoints;
    VAR speeddata cursorSpeed;
    VAR zonedata cursorZone;
    VAR signaldo cursorDO;
    VAR signalao cursorAO;

    ! Buffer of incoming messages
    CONST num msgBufferSize := 1000;
    VAR string msgBuffer{msgBufferSize};
    VAR num msgBufferReadCurrPos;
    VAR num msgBufferReadPrevPos;
    VAR num msgBufferReadLine;
    VAR num msgBufferWriteLine;
    VAR bool isMsgBufferWriteLineWrapped;
    VAR bool streamBufferPending;

    CONST string STR_DOUBLE_QUOTES := """";  ! A escaped double quote is written twice

    ! Buffer of pending actions
    CONST num actionsBufferSize := 1000;
    VAR action actions{actionsBufferSize};
    VAR num actionPosWrite;
    VAR num actionPosExecute;
    VAR bool isActionPosWriteWrapped;

    ! Buffer of responses
    VAR string response;



    !
    !  |\/| /\ ||\ |
    !  |  |/--\|| \|
    !

    ! Main entry point
    PROC Main()
        TPErase;

        ! Avoid signularities
        SingArea \Wrist;

        CursorsInitialize;
        ServerInitialize;

        MainLoop;
    ENDPROC

    ! The main loop the program will execute endlessly to read incoming messages
    ! and execute pending Actions
    PROC MainLoop()
        VAR action currentAction;
        VAR bool stopExecution := FALSE;

        WHILE stopExecution = FALSE DO
            ! Read the incoming buffer stream until flagges complete
            ! (must be done this way to avoid execution stack overflow through recursion)
            ReadStream;
            WHILE streamBufferPending = TRUE DO
                ReadStream;
            ENDWHILE
            ParseStream;

            ! Once the stream is flushed, execute all pending actions
            WHILE stopExecution = FALSE AND (actionPosExecute < actionPosWrite OR isActionPosWriteWrapped = TRUE) DO
                currentAction := actions{actionPosExecute};

                TEST currentAction.code
                CASE INST_MOVEL:
                    cursorTarget := GetRobTarget(currentAction);
                    MoveL cursorTarget, cursorSpeed, cursorZone, cursorTool, \WObj:=cursorWObj;

                CASE INST_MOVEJ:
                    cursorTarget := GetRobTarget(currentAction);
                    MoveJ cursorTarget, cursorSpeed, cursorZone, cursorTool, \WObj:=cursorWObj;

                CASE INST_MOVEABSJ:
                    cursorJoints := GetJointTarget(currentAction);
                    MoveAbsJ cursorJoints, cursorSpeed, cursorZone, cursorTool, \WObj:=cursorWObj;

                CASE INST_SPEED:
                    cursorSpeed := GetSpeedData(currentAction);

                CASE INST_ZONE:
                    cursorZone := GetZoneData(currentAction);

                CASE INST_WAITTIME:
                    WaitTime currentAction.p1;

                CASE INST_TPWRITE:
                    TPWrite currentAction.s1;

                CASE INST_TOOL:
                    cursorTool := GetToolData(currentAction);

                CASE INST_NOTOOL:
                    cursorTool := tool0;

                CASE INST_SETDO:
                    GetDataVal currentAction.s1, cursorDO;
                    SetDO cursorDO, currentAction.p1;

                CASE INST_SETDO:
                    GetDataVal currentAction.s1, cursorAO;
                    SetAO cursorAO, currentAction.p1;


                CASE INST_STOP_EXECUTION:
                    stopExecution := TRUE;

                CASE INST_GET_INFO:
                    SendInformation(currentAction);

                ENDTEST

                ! Send acknowledgement message
                SendAcknowledgement(currentAction);

                actionPosExecute := actionPosExecute + 1;
                IF actionPosExecute > actionsBufferSize THEN
                    actionPosExecute := 1;
                    isActionPosWriteWrapped := FALSE;
                ENDIF

            ENDWHILE
        ENDWHILE

        ServerFinalize;

        ERROR
            IF ERRNO = ERR_SYM_ACCESS THEN
                TPWrite "MACHINA ERROR: Could not find signal """ + currentAction.s1 + """";
                TPWrite "Errors will follow";
                IF USE_STRICT THEN EXIT; ENDIF
                STOP;
            ENDIF

    ENDPROC




    !   __ __                   __   ___  __
    !  /  /  \|\/||\/|/  \|\ ||/   /\ | |/  \|\ |
    !  \__\__/|  ||  |\__/| \||\__/--\| |\__/| \|
    !

    ! Start the TCP server
    PROC ServerInitialize()
        TPWrite "Initializing Machina Server...";
        ServerRecover;
    ENDPROC

    ! Recover from a disconnection
    PROC ServerRecover()
        SocketClose serverSocket;
        SocketClose clientSocket;
        SocketCreate serverSocket;
        SocketBind serverSocket, SERVER_IP, SERVER_PORT;
        SocketListen serverSocket;

        TPWrite "Waiting for incoming connection...";

        SocketAccept serverSocket, clientSocket \ClientAddress:=clientIp \Time:=WAIT_MAX;

        TPWrite "Connected to client: " + clientIp;
        TPWrite "Listening to TCP/IP commands...";

        ERROR
            IF ERRNO = ERR_SOCK_TIMEOUT THEN
                RETRY;
            ELSEIF ERRNO = ERR_SOCK_CLOSED THEN
                RETURN;
            ELSE
                ! No error recovery handling
            ENDIF
    ENDPROC

    ! Close sockets
    PROC ServerFinalize()
        SocketClose serverSocket;
        SocketClose clientSocket;
        WaitTime 2;
    ENDPROC

    ! Read string buffer from the client and try to parse it
    PROC ReadStream()
        VAR string strBuffer;
        VAR num strBufferLength;
        SocketReceive clientSocket \Str:=strBuffer \NoRecBytes:=strBufferLength \Time:=WAIT_MAX;
        ParseBuffer strBuffer, strBufferLength;

        ERROR
        IF ERRNO = ERR_SOCK_CLOSED THEN
            ServerRecover;
            RETRY;
        ENDIF
    ENDPROC

    ! Sends a short acknowledgement response to the client with the recently
    ! executed instruction and an optional id
    PROC SendAcknowledgement(action a)
        response := "";  ! acknowledgement responses do not start with the response char

        IF a.id <> 0 THEN
            response := response + STR_MESSAGE_ID_CHAR + NumToStr(a.id, 0) + STR_WHITE;
        ENDIF

        response := response + NumToStr(a.code, 0) + STR_MESSAGE_END_CHAR;

        SocketSend clientSocket \Str:=response;
    ENDPROC

    ! Responds to an information request by sending a formatted message
    PROC SendInformation(action a)
        response := STR_MESSAGE_RESPONSE_CHAR;  ! only send response char for information requests

        IF a.id <> 0 THEN
            response := response + STR_MESSAGE_ID_CHAR + NumToStr(a.id, 0) + STR_WHITE;
        ENDIF

        response := response + NumToStr(a.code, 0) + STR_WHITE + NumToStr(a.p1, 0) + STR_WHITE;

        TEST a.p1

        CASE 1:  ! Module version
            response := response + STR_DOUBLE_QUOTES + MACHINA_SERVER_VERSION + STR_DOUBLE_QUOTES;

        CASE 2:  ! IP and PORT
            response := response + STR_DOUBLE_QUOTES + SERVER_IP + STR_DOUBLE_QUOTES + STR_WHITE + NumToStr(SERVER_PORT, 0);

        ENDTEST

		response := response + STR_MESSAGE_END_CHAR;

        SocketSend clientSocket \Str:=response;
    ENDPROC




    !   __      __  __      __
    !  |__) /\ |__)(_ ||\ |/ _
    !  |   /--\| \ __)|| \|\__)
    !

    ! Parse an incoming string buffer, and decide what to do with it
    ! based on its quality
    PROC ParseBuffer(string sb, num sbl)
        VAR num statementsLength;
        VAR num endCurrentPos := 1;
        VAR num endLastPos := 1;
        VAR num endings := 0;

        endCurrentPos := StrFind(sb, 1, STR_MESSAGE_END_CHAR);
        WHILE endCurrentPos <= sbl DO
            endings := endings + 1;
            endLastPos := endCurrentPos;
            endCurrentPos := StrFind(sb, endCurrentPos + 1, STR_MESSAGE_END_CHAR);
        ENDWHILE

        ! Corrupt buffer
        IF endings = 0 THEN
            TPWrite "Received corrupt buffer";
            TPWrite sb;
            IF USE_STRICT THEN EXIT; ENDIF
        ENDIF

        ! Store the buffer
        StoreBuffer sb;

        ! Keep going if the chunk was trimmed
        streamBufferPending := endLastPos < sbl;

    ENDPROC

    ! Add a string buffer to the buffer of received messages
    PROC StoreBuffer(string buffer)
        IF isMsgBufferWriteLineWrapped = TRUE AND msgBufferWriteLine = msgBufferReadLine THEN
            TPWrite "MACHINA WARNING: memory overload. Maximum string buffer size is " + NumToStr(actionsBufferSize, 0);
            TPWrite "Reduce the amount of stream messages while they execute.";
            EXIT;
        ENDIF

        msgBuffer{msgBufferWriteLine} := buffer;
        msgBufferWriteLine := msgBufferWriteLine + 1;

        IF msgBufferWriteLine > msgBufferSize THEN
            msgBufferWriteLine := 1;
            isMsgBufferWriteLineWrapped := TRUE;
        ENDIF
    ENDPROC

    ! Parse the buffer of received messages into the buffer of pending actions
    PROC ParseStream()
        VAR string statement;
        VAR string part;
        VAR num partLength;
        VAR num lineLength;

        ! TPWrite "Parsing buffered stream, actionPosWrite: " + NumToStr(actionPosWrite, 0);

        WHILE msgBufferReadLine < msgBufferWriteLine OR isMsgBufferWriteLineWrapped = TRUE DO
            lineLength := StrLen(msgBuffer{msgBufferReadLine});

            WHILE msgBufferReadCurrPos <= lineLength DO
                msgBufferReadCurrPos := StrFind(msgBuffer{msgBufferReadLine}, msgBufferReadPrevPos, STR_MESSAGE_END_CHAR);

                partLength := msgBufferReadCurrPos - msgBufferReadPrevPos;
                part := part + StrPart(msgBuffer{msgBufferReadLine}, msgBufferReadPrevPos, partLength);  ! take the statement without the STR_MESSAGE_END_CHAR

                IF msgBufferReadCurrPos <= lineLength THEN
                    ParseStatement(part + STR_MESSAGE_END_CHAR);  ! quick and dirty add of the end_char... XD
                    part := "";
                ENDIF

                msgBufferReadCurrPos := msgBufferReadCurrPos + 1;
                msgBufferReadPrevPos := msgBufferReadCurrPos;
            ENDWHILE

            msgBufferReadCurrPos := 1;
            msgBufferReadPrevPos := 1;

            msgBufferReadLine := msgBufferReadLine + 1;
            IF msgBufferReadLine > msgBufferSize THEN
                msgBufferReadLine := 1;
                isMsgBufferWriteLineWrapped := FALSE;
            ENDIF
        ENDWHILE
    ENDPROC

    ! Parse a string representation of a statement into an Action
    ! and store it in the buffer.
    PROC ParseStatement(string st)
        ! This assumes a string formatted in the following form:
        ! [@IDNUM ]INSCODE[ "stringParam"][ p0 p1 p2 ... p11]STR_MESSAGE_END_CHAR

        VAR bool ok;
        VAR bool end;
        VAR num pos := 1;
        VAR num nPos;
        VAR string s;
        VAR num len;
        VAR num params{11};
        VAR num paramsPos := 1;
        VAR action a;

        ! Sanity
        len := StrLen(st);
        IF len < 2 THEN
            TPWrite "MACHINA ERROR: received too short of a message:";
            TPWrite st;
            IF USE_STRICT THEN EXIT; ENDIF
        ENDIF

        ! Does the message come with a leading ID?
        IF StrPart(st, 1, 1) = STR_MESSAGE_ID_CHAR THEN  ! can't strings be treated as char arrays? st{1} = ... ?
            nPos := StrFind(st, pos, STR_WHITE);
            IF nPos > len THEN
                TPWrite "MACHINA ERROR: incorrectly formatted message:";
                TPWrite st;
                IF USE_STRICT THEN EXIT; ENDIF
            ENDIF

            s := StrPart(st, 2, nPos - 2);
            ok := StrToVal(s, a.id);
            IF NOT ok THEN
                TPWrite "MACHINA ERROR: incorrectly formatted message:";
                TPWrite st;
                IF USE_STRICT THEN EXIT; ENDIF
                RETURN;
            ENDIF

            pos := nPos + 1;
        ENDIF

        ! Read instruction code
        nPos := StrFind(st, pos, STR_WHITE + STR_MESSAGE_END_CHAR);
        s := StrPart(st, pos, nPos - pos);
        ok := StrToVal(s, a.code);

        ! Couldn't read instruction code, discard this message
        IF NOT ok THEN
            TPWrite "MACHINA ERROR: received corrupt message:";
            TPWrite st;
            IF USE_STRICT THEN EXIT; ENDIF
            RETURN;
        ENDIF

        ! Is there any string param?
        pos := nPos + 1;
        nPos := StrFind(st, pos, STR_DOUBLE_QUOTES);
        IF nPos < len THEN
            pos := nPos + 1;
            nPos := StrFind(st, pos, STR_DOUBLE_QUOTES);  ! Find the matching double quote
            IF nPos < len THEN
                ! Succesful find of a double quote
                a.s1 := StrPart(st, pos, nPos - pos);
                pos := nPos + 2;  ! skip quotes and following char
                ! Reached end of string?
                IF pos > len THEN
                    end := TRUE;
                ENDIF
            ELSE
                TPWrite "MACHINA ERROR: corrupt message, missing closing double quotes";
                TPWrite st;
                IF USE_STRICT THEN EXIT; ENDIF
                RETURN;
            ENDIF
        ENDIF

        ! Parse rest of numerical characters
        WHILE end = FALSE DO
            nPos := StrFind(st, pos, STR_WHITE + STR_MESSAGE_END_CHAR);
            IF nPos > len THEN
                end := TRUE;
            ELSE
                ! Parameters should be parsed differently depending on code
                ! for example, a TPWrite action will have a string rather than nums...
                s := StrPart(st, pos, nPos - pos);
                ok := StrToVal(s, params{paramsPos});
                IF ok = FALSE THEN
                    end := TRUE;
                    TPWrite "MACHINA ERROR: received corrupt parameter:";
                    TPWrite s;
                    IF USE_STRICT THEN EXIT; ENDIF
                ENDIF
                paramsPos := paramsPos + 1;
                pos := nPos + 1;
            ENDIF
        ENDWHILE

        ! Quick and dity to avoid a huge IF ELSE statement... unassigned vars use zeros
        a.p1 := params{1};
        a.p2 := params{2};
        a.p3 := params{3};
        a.p4 := params{4};
        a.p5 := params{5};
        a.p6 := params{6};
        a.p7 := params{7};
        a.p8 := params{8};
        a.p9 := params{9};
        a.p10 := params{10};
        a.p11 := params{11};

        ! Save it to the buffer
        StoreAction a;

    ENDPROC

    ! Stores this action in the buffer
    PROC StoreAction(action a)
        IF isActionPosWriteWrapped = TRUE AND actionPosWrite = actionPosExecute THEN
            TPWrite "MACHINA WARNING: memory overload. Maximum Action buffer size is " + NumToStr(actionsBufferSize, 0);
            TPWrite "Reduce the amount of stream messages while they execute.";
            EXIT;
        ENDIF

        actions{actionPosWrite} := a;
        actionPosWrite := actionPosWrite + 1;

        IF actionPosWrite > actionsBufferSize THEN
            actionPosWrite := 1;
            isActionPosWriteWrapped := TRUE;
        ENDIF

    ENDPROC





    !          ___     ___      __         _____  __      __
    !      /  \ | ||  | | \_/  |_ /  \|\ |/   | |/  \|\ |(_
    !      \__/ | ||__| |  |   |  \__/| \|\__ | |\__/| \|__)
    !

    ! Initialize robot cursor values to current state and some defaults
    PROC CursorsInitialize()
        msgBufferReadCurrPos := 1;
        msgBufferReadPrevPos := 1;
        msgBufferReadLine := 1;
        msgBufferWriteLine := 1;
        isMsgBufferWriteLineWrapped := FALSE;
        streamBufferPending := FALSE;

        actionPosWrite := 1;
        actionPosExecute := 1;
        isActionPosWriteWrapped := FALSE;

        response := "";

        cursorTool := tool0;
        cursorWObj := wobj0;
        cursorJoints := CJointT();
        cursorTarget := CRobT();
        cursorSpeed := v20;
        cursorZone := z5;
    ENDPROC

    ! Return the jointtarget represented by an Action
    FUNC jointtarget GetJointTarget(action a)
        RETURN [[a.p1, a.p2, a.p3, a.p4, a.p5, a.p6], [9E9,9E9,9E9,9E9,9E9,9E9]];
    ENDFUNC

    ! Return the robottarget represented by an Action
    FUNC robtarget GetRobTarget(action a)
        RETURN [[a.p1, a.p2, a.p3], [a.p4, a.p5, a.p6, a.p7], [0,0,0,0], [9E9,9E9,9E9,9E9,9E9,9E9]];
    ENDFUNC

    FUNC speeddata GetSpeedData(action a)
        ! Fill in the gaps
        IF a.p2 = 0 THEN
            a.p2 := a.p1;
        ENDIF
        IF a.p3 = 0 THEN
            a.p3 := 5000;
        ENDIF
        IF a.p4 = 0 THEN
            a.p4 := 1000;
        ENDIF

        RETURN [a.p1, a.p2, a.p3, a.p4];
    ENDFUNC

    ! Return the zonedata represented by an Action
    FUNC zonedata GetZoneData(action a)
        IF a.p1 = 0 THEN
            RETURN fine;
        ENDIF

        ! Fill in some gaps
        IF a.p2 = 0 THEN
            a.p2 := 1.5 * a.p1;
        ENDIF
        IF a.p3 = 0 THEN
            a.p3 := 1.5 * a.p1;
        ENDIF
        IF a.p4 = 0 THEN
            a.p4 := 0.1 * a.p1;
        ENDIF
        IF a.p5 = 0 THEN
            a.p5 := 1.5 * a.p1;
        ENDIF
        IF a.p6 = 0 THEN
            a.p6 := 0.1 * a.p1;
        ENDIF

        RETURN [FALSE, a.p1, a.p2, a.p3, a.p4, a.p5, a.p6];
    ENDFUNC

    ! Return the tooldata represented by an Action
    FUNC tooldata GetToolData(action a)
        ! If missing weight info
        IF a.p8 = 0 THEN
            a.p8 := 1;
        ENDIF

        ! If missing center of gravity info
        IF a.p9 = 0 THEN
            a.p9 := 0.5 * a.p1;
        ENDIF
        IF a.p10 = 0 THEN
            a.p10 := 0.5 * a.p2;
        ENDIF
        IF a.p11 = 0 THEN
            a.p11 := 0.5 * a.p3;
        ENDIF

        RETURN [TRUE, [[a.p1, a.p2, a.p3], [a.p4, a.p5, a.p6, a.p7]],
            [a.p8, [a.p9, a.p10, a.p11], [1, 0, 0, 0], 0, 0, 0]];
    ENDFUNC

    ! TPWrite a string representation of an Action
    PROC log(action a)
        TPWrite "ACTION: " + NumToStr(a.code, 0) + " "
            + a.s1 + " "
            + NumToStr(a.p1, 0) + " " + NumToStr(a.p2, 0) + " "
            + NumToStr(a.p3, 0) + " " + NumToStr(a.p4, 0) + " "
            + NumToStr(a.p5, 0) + " " + NumToStr(a.p6, 0) + " "
            + NumToStr(a.p7, 0) + " " + NumToStr(a.p8, 0) + " "
            + NumToStr(a.p9, 0) + " " + NumToStr(a.p10, 0) + " "
            + NumToStr(a.p11, 0) + STR_MESSAGE_END_CHAR;
    ENDPROC

ENDMODULE
