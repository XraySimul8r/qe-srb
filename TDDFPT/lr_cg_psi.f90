!
! Copyright (C) 2001 PWSCF group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!
!-----------------------------------------------------------------
subroutine lr_cg_psi (lda, n, m, psi, h_diag)
!-----------------------------------------------------------------
!
!    This routine gives a preconditioning to the linear system solver.
!    The preconditioning is diagonal in reciprocal space
!
!
USE kinds, only : DP
implicit none
!
integer :: lda, n, m
                         ! input: the leading dimension of the psi vecto
                         ! input: the real dimension of the vector
                         ! input: the number of vectors
!
complex(kind=DP) :: psi (lda, m)
                         ! inp/out: the vector to be preconditioned
!
real(kind=DP) :: h_diag (lda, m)
                           ! input: the preconditioning vector
!
integer :: k, i
                         ! counter on bands
                         ! counter on the elements of the vector
do k = 1, m
   do i = 1, n
      psi (i, k) = psi (i, k) * h_diag (i, k)
   enddo
enddo
return
end subroutine lr_cg_psi
