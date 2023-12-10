import React from 'react';
import Box from '@mui/material/Box';
import Typography from '@mui/material/Typography';

const Footer: React.FC = () => {
	return (
		<Box
			sx={{
				width: '100%',
				backgroundColor: '#0D2F4B',
				padding: '20px',
				color: '#fbfbfb',
				display: 'flex',
				justifyContent: 'center',
				alignItems: 'center',
				bottom: 0,
				mt: 'auto', // for pushing footer to the bottom if using flex layout
			}}
		>
			<Typography
				variant="body1"
				sx={{
					textAlign: 'center',
					fontSize: '15px',
					fontFamily: 'Libre Baskerville, serif',
				}}
			>
				© {new Date().getFullYear()} Edison Sáez E. All rights reserved.
			</Typography>
		</Box>
	);
};

export default Footer;
