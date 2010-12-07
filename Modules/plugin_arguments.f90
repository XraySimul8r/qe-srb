!
! Copyright (C) 2010 Quantum ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!----------------------------------------------------------------------------
SUBROUTINE plugin_arguments()
  !-----------------------------------------------------------------------------
  !
  ! check for presence of command-line option "-plugin_name" or "--plugin_name"
  ! where "plugin_name" has to be set here. If such option is found, variable
  ! "use_plugin_name" is set and usage of "plugin_name" is thus enabled.
  ! Currently implemented: "plumed" (case insensitive)
  !
  USE kinds,         ONLY : DP
  !
  USE io_global,     ONLY : stdout
  !
  USE plugin_flags
  !
  !
  IMPLICIT NONE
  !
  INTEGER  :: iiarg, nargs, iargc, ierra, l
  CHARACTER (len=1), EXTERNAL ::  lowercase
  CHARACTER (len=256) :: arg
  !
  !
#if defined(__ABSOFT)
#   define getarg getarg_
#   define iargc  iargc_
#endif
  !
  nargs = iargc()
  ! add here more plugins
  use_plumed = .false.
  !
  DO iiarg = 1, nargs 
    CALL getarg( iiarg, plugin_name)
    IF ( plugin_name(1:1) == '-') THEN
       arg = ' '
       DO l=2, LEN_TRIM (plugin_name)
          arg(l-1:l-1) = lowercase (plugin_name(l:l))
       END DO
!       write(0,*) "plugin_name: ", trim(arg)
       ! add here more plugins
       IF ( TRIM(arg)=='plumed' .OR. TRIM(arg)=='-plumed' ) THEN
          use_plumed = .true.
       END IF
    ENDIF
  ENDDO
  ! add here more plugins
  !
  RETURN
  !
END SUBROUTINE plugin_arguments
!
!
SUBROUTINE plugin_arguments_bcast(root,comm)
!
! bcast plugin arguments
!
USE mp_global, ONLY : mp_bcast
USE plugin_flags
!
IMPLICIT NONE
!
integer :: root
integer :: comm
!
CALL mp_bcast(use_plumed,root,comm)
!
write(0,*) "use_plumed: ", use_plumed
!
RETURN
!
END SUBROUTINE plugin_arguments_bcast
